#include "copus.h"
#include <AudioToolbox/AudioToolbox.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#define OPUS_RATE 48000

typedef struct {
    FILE *file;
    uint32_t serial;
    int have_serial;
    unsigned char *page;
    int page_len;
    int page_pos;
    unsigned char segments[255];
    int segment_count;
    int segment_index;
    unsigned char *packet;
    size_t packet_len;
    size_t packet_cap;
    int eof;
} OggReader;

struct COpusDecoder {
    OggReader reader;
    unsigned char *head;
    int head_len;
    int channels;
    int pre_skip;
    long long frames;
    char **tags;
    int tag_count;
    AudioConverterRef converter;
    int converter_ready;
    int input_eof;
    int error;
};

static int64_t read_i64(const unsigned char *p) {
    uint64_t v = 0;
    for (int i = 0; i < 8; i++) v |= (uint64_t)p[i] << (8 * i);
    return (int64_t)v;
}

static uint32_t read_u32(const unsigned char *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static int reader_open(OggReader *reader, const char *path) {
    memset(reader, 0, sizeof(*reader));
    reader->file = fopen(path, "rb");
    return reader->file != NULL;
}

static void reader_close(OggReader *reader) {
    if (reader->file) fclose(reader->file);
    free(reader->page);
    free(reader->packet);
    memset(reader, 0, sizeof(*reader));
}

static int reader_read_page(OggReader *reader) {
    while (!reader->eof) {
        unsigned char header[27];
        if (fread(header, 1, sizeof(header), reader->file) != sizeof(header)) {
            reader->eof = 1;
            return 0;
        }
        if (memcmp(header, "OggS", 4) != 0 || header[4] != 0) {
            reader->eof = 1;
            return 0;
        }
        int segments = header[26];
        unsigned char table[255];
        if (fread(table, 1, (size_t)segments, reader->file) != (size_t)segments) {
            reader->eof = 1;
            return 0;
        }
        int body = 0;
        for (int i = 0; i < segments; i++) body += table[i];
        unsigned char *page = (unsigned char *)malloc((size_t)body);
        if (!page) { reader->eof = 1; return 0; }
        if (body && fread(page, 1, (size_t)body, reader->file) != (size_t)body) {
            free(page);
            reader->eof = 1;
            return 0;
        }
        uint32_t serial = (uint32_t)header[14] | ((uint32_t)header[15] << 8)
                        | ((uint32_t)header[16] << 16) | ((uint32_t)header[17] << 24);
        if (!reader->have_serial) {
            reader->serial = serial;
            reader->have_serial = 1;
        }
        if (serial != reader->serial) {
            free(page);
            continue;
        }
        free(reader->page);
        reader->page = page;
        reader->page_len = body;
        reader->page_pos = 0;
        reader->segment_count = segments;
        reader->segment_index = 0;
        memcpy(reader->segments, table, (size_t)segments);
        return 1;
    }
    return 0;
}

static int reader_next_packet(OggReader *reader, unsigned char **packet, int *length) {
    reader->packet_len = 0;
    while (1) {
        if (!reader->page || reader->segment_index >= reader->segment_count) {
            if (!reader_read_page(reader)) return 0;
        }
        while (reader->segment_index < reader->segment_count) {
            int size = reader->segments[reader->segment_index++];
            if (reader->packet_len + (size_t)size > reader->packet_cap) {
                size_t cap = reader->packet_cap ? reader->packet_cap : 4096;
                while (cap < reader->packet_len + (size_t)size) cap *= 2;
                unsigned char *grown = (unsigned char *)realloc(reader->packet, cap);
                if (!grown) return 0;
                reader->packet = grown;
                reader->packet_cap = cap;
            }
            if (size > 0) {
                if (reader->page_pos + size > reader->page_len) return 0;
                memcpy(reader->packet + reader->packet_len, reader->page + reader->page_pos, (size_t)size);
                reader->page_pos += size;
                reader->packet_len += (size_t)size;
            }
            if (size < 255) {
                *packet = reader->packet;
                *length = (int)reader->packet_len;
                return reader->packet_len > 0;
            }
        }
        if (reader->segment_count == 0) continue;
    }
}

static int parse_tags(COpusDecoder *decoder, const unsigned char *packet, int length) {
    if (length < 12 || memcmp(packet, "OpusTags", 8) != 0) return 0;
    int offset = 8;
    uint32_t vendor = read_u32(packet + offset);
    offset += 4;
    if (vendor > (uint32_t)(length - offset)) return 0;
    offset += (int)vendor;
    if (offset + 4 > length) return 0;
    uint32_t count = read_u32(packet + offset);
    offset += 4;
    if (count > 10000) return 0;
    decoder->tags = (char **)calloc(count ? count : 1, sizeof(char *));
    if (!decoder->tags) return 0;
    for (uint32_t index = 0; index < count && offset + 4 <= length; index++) {
        uint32_t size = read_u32(packet + offset);
        offset += 4;
        if (size > (uint32_t)(length - offset)) break;
        char *value = (char *)malloc((size_t)size + 1);
        if (!value) break;
        memcpy(value, packet + offset, size);
        value[size] = 0;
        decoder->tags[decoder->tag_count++] = value;
        offset += (int)size;
    }
    return 1;
}

static int opus_packet_frames(const unsigned char *packet, int length) {
    if (length < 1) return 0;
    int config = packet[0] >> 3;
    int frame_size;
    if (config < 12) {
        static const int silk[] = {480, 960, 1920, 2880};
        frame_size = silk[config & 3];
    } else if (config < 16) {
        static const int hybrid[] = {480, 960, 480, 960};
        frame_size = hybrid[config & 3];
    } else {
        static const int celt[] = {120, 240, 480, 960};
        frame_size = celt[config & 3];
    }
    int count = packet[0] & 3;
    if (count == 0) count = 1;
    else if (count == 1 || count == 2) count = 2;
    else {
        if (length < 2) return 0;
        count = packet[1] & 0x3F;
    }
    return frame_size * count;
}

static long long scan_last_granule(const char *path, uint32_t serial) {
    FILE *file = fopen(path, "rb");
    if (!file) return 0;
    long long last = 0;
    unsigned char header[27];
    while (fread(header, 1, sizeof(header), file) == sizeof(header)) {
        if (memcmp(header, "OggS", 4) != 0 || header[4] != 0) break;
        int segments = header[26];
        unsigned char table[255];
        if (fread(table, 1, (size_t)segments, file) != (size_t)segments) break;
        long body = 0;
        for (int i = 0; i < segments; i++) body += table[i];
        uint32_t page_serial = (uint32_t)header[14] | ((uint32_t)header[15] << 8)
                             | ((uint32_t)header[16] << 16) | ((uint32_t)header[17] << 24);
        int64_t granule = read_i64(header + 6);
        if (page_serial == serial && granule > last) last = granule;
        if (fseek(file, body, SEEK_CUR) != 0) break;
    }
    fclose(file);
    return last;
}

COpusDecoder *copus_open(const char *path) {
    if (!path) return NULL;
    COpusDecoder *decoder = (COpusDecoder *)calloc(1, sizeof(COpusDecoder));
    if (!decoder) return NULL;
    if (!reader_open(&decoder->reader, path)) { free(decoder); return NULL; }

    unsigned char *packet = NULL;
    int length = 0;
    if (!reader_next_packet(&decoder->reader, &packet, &length) || length < 19 ||
        memcmp(packet, "OpusHead", 8) != 0) {
        copus_close(decoder);
        return NULL;
    }
    decoder->head_len = length;
    decoder->head = (unsigned char *)malloc((size_t)length);
    if (!decoder->head) { copus_close(decoder); return NULL; }
    memcpy(decoder->head, packet, (size_t)length);
    decoder->channels = packet[9];
    decoder->pre_skip = packet[10] | (packet[11] << 8);
    if (decoder->channels <= 0 || decoder->channels > 2) {
        copus_close(decoder);
        return NULL;
    }

    if (reader_next_packet(&decoder->reader, &packet, &length)) {
        parse_tags(decoder, packet, length);
    }

    long long granule = scan_last_granule(path, decoder->reader.serial);
    if (granule > decoder->pre_skip) decoder->frames = granule - decoder->pre_skip;
    return decoder;
}

void copus_close(COpusDecoder *decoder) {
    if (!decoder) return;
    if (decoder->converter) AudioConverterDispose(decoder->converter);
    reader_close(&decoder->reader);
    free(decoder->head);
    for (int i = 0; i < decoder->tag_count; i++) free(decoder->tags[i]);
    free(decoder->tags);
    free(decoder);
}

int copus_info(COpusDecoder *decoder, int *channels, int *rate, long long *frames) {
    if (!decoder) return -1;
    if (channels) *channels = decoder->channels;
    if (rate) *rate = OPUS_RATE;
    if (frames) *frames = decoder->frames;
    return 0;
}

static OSStatus converter_input(AudioConverterRef converter, UInt32 *ioNumberDataPackets,
                                AudioBufferList *ioData, AudioStreamPacketDescription **description,
                                void *userData) {
    COpusDecoder *decoder = (COpusDecoder *)userData;
    (void)converter;
    if (decoder->input_eof) {
        *ioNumberDataPackets = 0;
        return noErr;
    }
    unsigned char *packet = NULL;
    int length = 0;
    if (!reader_next_packet(&decoder->reader, &packet, &length) || length <= 0) {
        decoder->input_eof = 1;
        *ioNumberDataPackets = 0;
        return noErr;
    }
    int frames = opus_packet_frames(packet, length);
    if (frames <= 0) {
        *ioNumberDataPackets = 0;
        return noErr;
    }
    ioData->mNumberBuffers = 1;
    ioData->mBuffers[0].mNumberChannels = (UInt32)decoder->channels;
    ioData->mBuffers[0].mData = packet;
    ioData->mBuffers[0].mDataByteSize = (UInt32)length;
    *ioNumberDataPackets = 1;
    if (description) {
        static AudioStreamPacketDescription packetDescription;
        packetDescription.mStartOffset = 0;
        packetDescription.mVariableFramesInPacket = (UInt32)frames;
        packetDescription.mDataByteSize = (UInt32)length;
        *description = &packetDescription;
    }
    return noErr;
}

static int create_converter(COpusDecoder *decoder) {
    AudioStreamBasicDescription input = {0};
    input.mSampleRate = OPUS_RATE;
    input.mFormatID = kAudioFormatOpus;
    input.mChannelsPerFrame = (UInt32)decoder->channels;
    input.mFramesPerPacket = 960;

    AudioStreamBasicDescription output = {0};
    output.mSampleRate = OPUS_RATE;
    output.mFormatID = kAudioFormatLinearPCM;
    output.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    output.mChannelsPerFrame = (UInt32)decoder->channels;
    output.mBitsPerChannel = 32;
    output.mFramesPerPacket = 1;
    output.mBytesPerFrame = 4 * (UInt32)decoder->channels;
    output.mBytesPerPacket = output.mBytesPerFrame;

    OSStatus status = AudioConverterNew(&input, &output, &decoder->converter);
    if (status != noErr) return -1;
    status = AudioConverterSetProperty(decoder->converter, kAudioConverterDecompressionMagicCookie,
                                       (UInt32)decoder->head_len, decoder->head);
    if (status != noErr) return -1;
    decoder->converter_ready = 1;
    return 0;
}

int copus_read(COpusDecoder *decoder, float *samples, int max_frames) {
    if (!decoder || !samples || max_frames <= 0) return -1;
    if (decoder->error) return -1;
    if (!decoder->converter_ready && create_converter(decoder) != 0) {
        decoder->error = 1;
        return -1;
    }
    AudioBufferList list;
    list.mNumberBuffers = 1;
    list.mBuffers[0].mNumberChannels = (UInt32)decoder->channels;
    list.mBuffers[0].mData = samples;
    list.mBuffers[0].mDataByteSize = (UInt32)(max_frames * decoder->channels * (int)sizeof(float));
    UInt32 frames = (UInt32)max_frames;
    OSStatus status = AudioConverterFillComplexBuffer(decoder->converter, converter_input,
                                                      decoder, &frames, &list, NULL);
    if (status != noErr) {
        decoder->error = 1;
        return -1;
    }
    return (int)frames;
}

int copus_tag_count(COpusDecoder *decoder) {
    return decoder ? decoder->tag_count : 0;
}

const char *copus_tag(COpusDecoder *decoder, int index) {
    if (!decoder || index < 0 || index >= decoder->tag_count) return NULL;
    return decoder->tags[index];
}
