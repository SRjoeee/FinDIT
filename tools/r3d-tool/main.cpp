// r3d-tool: CLI bridge for RED R3D SDK
// Commands: probe, extract-frame, extract-frames, extract-audio
//
// Outputs JSON on stdout, errors on stderr.
// Exit 0 = success, 1 = error.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <string>
#include <vector>

#include "R3DSDK.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <CoreServices/CoreServices.h>

using namespace R3DSDK;

#ifndef R3DSDK_DYLIB_PATH
#define R3DSDK_DYLIB_PATH ""
#endif

// ============================================================
// Helpers
// ============================================================

static const char* getDylibPath() {
    const char* env = getenv("R3DSDK_LIB_PATH");
    if (env && env[0]) return env;
    const char* compiled = R3DSDK_DYLIB_PATH;
    if (compiled[0]) return compiled;
    return ".";
}

static void* alignedAlloc(size_t alignment, size_t size) {
    void* ptr = nullptr;
    if (posix_memalign(&ptr, alignment, size) != 0) return nullptr;
    return ptr;
}

static std::string jsonEscape(const std::string& s) {
    std::string result;
    result.reserve(s.size());
    for (char c : s) {
        switch (c) {
            case '"':  result += "\\\""; break;
            case '\\': result += "\\\\"; break;
            case '\n': result += "\\n"; break;
            case '\r': result += "\\r"; break;
            case '\t': result += "\\t"; break;
            default:   result += c;
        }
    }
    return result;
}

// ============================================================
// BGRA -> JPEG via CoreGraphics
// ============================================================

static bool writeBGRAasJPEG(const void* bgra, size_t width, size_t height,
                             const char* outputPath, int maxDim) {
    size_t outW = width, outH = height;
    if (maxDim > 0) {
        size_t shortEdge = (outW < outH) ? outW : outH;
        if ((int)shortEdge > maxDim) {
            double scale = (double)maxDim / (double)shortEdge;
            outW = (size_t)(outW * scale);
            outH = (size_t)(outH * scale);
            // Ensure even dimensions
            outW = (outW + 1) & ~(size_t)1;
            outH = (outH + 1) & ~(size_t)1;
        }
    }

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    if (!cs) return false;

    // Create source CGImage from BGRA buffer
    CGDataProviderRef dp = CGDataProviderCreateWithData(
        nullptr, bgra, width * height * 4, nullptr);
    if (!dp) { CGColorSpaceRelease(cs); return false; }

    CGBitmapInfo bmpInfo = kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst;
    CGImageRef srcImg = CGImageCreate(
        width, height, 8, 32, width * 4, cs, bmpInfo,
        dp, nullptr, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(dp);
    if (!srcImg) { CGColorSpaceRelease(cs); return false; }

    // Resize if needed
    CGImageRef finalImg = srcImg;
    CGContextRef resizeCtx = nullptr;
    if (outW != width || outH != height) {
        resizeCtx = CGBitmapContextCreate(
            nullptr, outW, outH, 8, outW * 4, cs, bmpInfo);
        if (resizeCtx) {
            CGContextSetInterpolationQuality(resizeCtx, kCGInterpolationHigh);
            CGContextDrawImage(resizeCtx, CGRectMake(0, 0, outW, outH), srcImg);
            finalImg = CGBitmapContextCreateImage(resizeCtx);
        }
    }

    // Write JPEG
    CFStringRef cfPath = CFStringCreateWithCString(
        nullptr, outputPath, kCFStringEncodingUTF8);
    CFURLRef url = CFURLCreateWithFileSystemPath(
        nullptr, cfPath, kCFURLPOSIXPathStyle, false);
    CFRelease(cfPath);

    CGImageDestinationRef dest = CGImageDestinationCreateWithURL(
        url, CFSTR("public.jpeg"), 1, nullptr);
    CFRelease(url);
    if (!dest) {
        if (resizeCtx) { CGImageRelease(finalImg); CGContextRelease(resizeCtx); }
        CGImageRelease(srcImg); CGColorSpaceRelease(cs);
        return false;
    }

    float q = 0.85f;
    CFNumberRef quality = CFNumberCreate(nullptr, kCFNumberFloat32Type, &q);
    const void* keys[] = { kCGImageDestinationLossyCompressionQuality };
    const void* vals[] = { quality };
    CFDictionaryRef props = CFDictionaryCreate(
        nullptr, keys, vals, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

    CGImageDestinationAddImage(dest, finalImg, props);
    bool ok = CGImageDestinationFinalize(dest);

    CFRelease(props); CFRelease(quality); CFRelease(dest);
    if (resizeCtx) { CGImageRelease(finalImg); CGContextRelease(resizeCtx); }
    CGImageRelease(srcImg); CGColorSpaceRelease(cs);
    return ok;
}

// ============================================================
// probe
// ============================================================

static int cmd_probe(const char* filePath) {
    R3DSDK::Clip clip;
    if (clip.LoadFrom(filePath) != R3DSDK::LSClipLoaded) {
        fprintf(stderr, "Error: Cannot load file: %s\n", filePath);
        return 1;
    }

    size_t w = clip.Width(), h = clip.Height();
    float fps = clip.VideoAudioFramerate();
    size_t frames = clip.VideoFrameCount();
    double duration = (fps > 0) ? (double)frames / fps : 0.0;
    size_t audioChannels = clip.AudioChannelCount();
    unsigned int sampleRate = (audioChannels > 0)
        ? clip.MetadataItemAsInt(RMD_SAMPLERATE) : 0;
    if (audioChannels > 0 && sampleRate == 0) sampleRate = 48000;

    std::string codec = clip.MetadataExists(RMD_REDCODE)
        ? clip.MetadataItemAsString(RMD_REDCODE) : "REDCODE";
    std::string camera = clip.MetadataExists(RMD_CAMERA_MODEL)
        ? clip.MetadataItemAsString(RMD_CAMERA_MODEL) : "";

    printf("{\"width\":%zu,\"height\":%zu,\"fps\":%.3f,\"frameCount\":%zu,"
           "\"duration\":%.3f,\"codec\":\"%s\",\"audioChannels\":%zu,"
           "\"audioSampleRate\":%u,\"camera\":\"%s\"}\n",
           w, h, fps, frames, duration,
           jsonEscape(codec).c_str(), audioChannels, sampleRate,
           jsonEscape(camera).c_str());

    clip.Close();
    return 0;
}

// ============================================================
// Single frame decode (shared by extract-frame/extract-frames)
// ============================================================

static int decodeFrame(R3DSDK::Clip& clip, double timeSec,
                        const char* outputPath, int maxDim) {
    size_t fullW = clip.Width(), fullH = clip.Height();
    float fps = clip.VideoAudioFramerate();
    size_t totalFrames = clip.VideoFrameCount();

    // Time -> frame index
    size_t frameNo = (fps > 0 && timeSec > 0)
        ? (size_t)(timeSec * fps) : 0;
    if (frameNo >= totalFrames && totalFrames > 0)
        frameNo = totalFrames - 1;

    // Choose decode resolution: quarter for moderate, eighth for very large
    auto mode = R3DSDK::DECODE_QUARTER_RES_GOOD;
    size_t decW = fullW / 4, decH = fullH / 4;
    if (decW > 2048) {
        mode = R3DSDK::DECODE_EIGHT_RES_GOOD;
        decW = fullW / 8; decH = fullH / 8;
    }
    if (decW == 0) decW = 1;
    if (decH == 0) decH = 1;

    // BGRA 8-bit = 4 bytes per pixel
    size_t bufSize = decW * decH * 4;
    void* buf = alignedAlloc(16, bufSize);
    if (!buf) {
        fprintf(stderr, "Error: alloc failed (%zu bytes)\n", bufSize);
        return 1;
    }

    R3DSDK::VideoDecodeJob job;
    job.Mode = mode;
    job.PixelType = R3DSDK::PixelType_8Bit_BGRA_Interleaved;
    job.OutputBuffer = buf;
    job.OutputBufferSize = bufSize;

    auto ds = clip.DecodeVideoFrame(frameNo, job);
    if (ds != R3DSDK::DSDecodeOK) {
        fprintf(stderr, "Error: decode failed (status=%d, frame=%zu)\n",
                (int)ds, frameNo);
        free(buf);
        return 1;
    }

    bool ok = writeBGRAasJPEG(buf, decW, decH, outputPath, maxDim);
    free(buf);
    if (!ok) {
        fprintf(stderr, "Error: JPEG write failed: %s\n", outputPath);
        return 1;
    }
    return 0;
}

// ============================================================
// extract-frame
// ============================================================

static int cmd_extract_frame(const char* filePath, double timeSec,
                              const char* outputPath, int maxDim) {
    R3DSDK::Clip clip;
    if (clip.LoadFrom(filePath) != R3DSDK::LSClipLoaded) {
        fprintf(stderr, "Error: Cannot load file: %s\n", filePath);
        return 1;
    }
    int r = decodeFrame(clip, timeSec, outputPath, maxDim);
    clip.Close();
    return r;
}

// ============================================================
// extract-frames
// ============================================================

static int cmd_extract_frames(const char* filePath, const char* timesJson,
                               const char* outputDir, int maxDim) {
    // Parse JSON array: [1.0, 5.0, 10.0]
    std::vector<double> times;
    const char* p = timesJson;
    while (*p && *p != '[') p++;
    if (*p == '[') p++;
    while (*p) {
        while (*p == ' ' || *p == ',' || *p == '\n') p++;
        if (*p == ']' || *p == '\0') break;
        char* end = nullptr;
        double t = strtod(p, &end);
        if (end == p) break;
        times.push_back(t);
        p = end;
    }
    if (times.empty()) {
        fprintf(stderr, "Error: no timestamps in JSON array\n");
        return 1;
    }

    R3DSDK::Clip clip;
    if (clip.LoadFrom(filePath) != R3DSDK::LSClipLoaded) {
        fprintf(stderr, "Error: Cannot load file: %s\n", filePath);
        return 1;
    }

    printf("[");
    for (size_t i = 0; i < times.size(); i++) {
        char path[2048];
        snprintf(path, sizeof(path), "%s/frame_%04zu.jpg", outputDir, i);
        int ret = decodeFrame(clip, times[i], path, maxDim);
        if (i > 0) printf(",");
        if (ret == 0) {
            printf("\"%s\"", path);
        } else {
            printf("null");
            fprintf(stderr, "Warning: frame at %.3f failed\n", times[i]);
        }
    }
    printf("]\n");

    clip.Close();
    return 0;
}

// ============================================================
// WAV header
// ============================================================

#pragma pack(push, 1)
struct WAVHeader {
    char     riff[4]      = {'R','I','F','F'};
    uint32_t fileSize      = 0;
    char     wave[4]      = {'W','A','V','E'};
    char     fmt[4]       = {'f','m','t',' '};
    uint32_t fmtSize      = 16;
    uint16_t audioFmt     = 1;      // PCM
    uint16_t channels     = 0;
    uint32_t sampleRate   = 0;
    uint32_t byteRate     = 0;
    uint16_t blockAlign   = 0;
    uint16_t bitsPerSamp  = 0;
    char     data[4]      = {'d','a','t','a'};
    uint32_t dataSize     = 0;
};
#pragma pack(pop)

// ============================================================
// extract-audio
// ============================================================

static int cmd_extract_audio(const char* filePath, const char* outputPath) {
    R3DSDK::Clip clip;
    if (clip.LoadFrom(filePath) != R3DSDK::LSClipLoaded) {
        fprintf(stderr, "Error: Cannot load file: %s\n", filePath);
        return 1;
    }

    size_t channels = clip.AudioChannelCount();
    if (channels == 0) {
        fprintf(stderr, "Error: no audio track in this clip\n");
        clip.Close();
        return 1;
    }

    unsigned int sr = clip.MetadataItemAsInt(RMD_SAMPLERATE);
    if (sr == 0) sr = 48000;
    bool isFloat = clip.MetadataExists(RMD_AUDIO_FORMAT)
        && clip.MetadataItemAsInt(RMD_AUDIO_FORMAT) == 1;
    unsigned long long totalSamples = clip.AudioSampleCount();

    FILE* fout = fopen(outputPath, "wb");
    if (!fout) {
        fprintf(stderr, "Error: cannot open output: %s\n", outputPath);
        clip.Close();
        return 1;
    }

    // Write placeholder WAV header (update at end)
    WAVHeader hdr;
    hdr.channels    = (uint16_t)channels;
    hdr.sampleRate  = sr;
    hdr.bitsPerSamp = 16;
    hdr.blockAlign  = (uint16_t)(channels * 2);
    hdr.byteRate    = sr * hdr.blockAlign;
    fwrite(&hdr, sizeof(hdr), 1, fout);

    // Audio buffer: 512-byte aligned, decode 1 second at a time
    const size_t chunkSamples = 48000;  // per-channel
    const size_t chunkBytes = chunkSamples * channels * 4;  // 32-bit per sample
    void* buf = alignedAlloc(512, chunkBytes);
    if (!buf) {
        fprintf(stderr, "Error: audio buffer alloc failed\n");
        fclose(fout); clip.Close();
        return 1;
    }

    std::vector<int16_t> out16(chunkSamples * channels);
    uint32_t dataBytes = 0;
    unsigned long long decoded = 0;

    while (decoded < totalSamples) {
        size_t want = chunkSamples;
        if (totalSamples - decoded < want)
            want = (size_t)(totalSamples - decoded);

        size_t got = want;
        R3DSDK::DecodeStatus ds;
        if (isFloat) {
            ds = clip.DecodeFloatAudio(decoded, &got, buf, chunkBytes);
        } else {
            ds = clip.DecodeAudio(decoded, &got, buf, chunkBytes);
        }

        if (ds != R3DSDK::DSDecodeOK || got == 0) break;

        size_t totalValues = got * channels;
        if (isFloat) {
            // 32-bit IEEE float -> 16-bit PCM
            const float* f = (const float*)buf;
            for (size_t i = 0; i < totalValues; i++) {
                float s = f[i];
                if (s > 1.0f) s = 1.0f;
                if (s < -1.0f) s = -1.0f;
                out16[i] = (int16_t)(s * 32767.0f);
            }
        } else {
            // 32-bit big-endian integer (24-bit MSB-aligned) -> 16-bit PCM
            const unsigned char* raw = (const unsigned char*)buf;
            for (size_t i = 0; i < totalValues; i++) {
                const unsigned char* p = raw + i * 4;
                // Take upper 16 bits of the 24-bit sample (big-endian: MSB first)
                out16[i] = (int16_t)((p[0] << 8) | p[1]);
            }
        }

        size_t wb = totalValues * 2;
        fwrite(out16.data(), 1, wb, fout);
        dataBytes += (uint32_t)wb;
        decoded += got;
    }

    // Update WAV header with actual sizes
    hdr.dataSize = dataBytes;
    hdr.fileSize = 36 + dataBytes;
    fseek(fout, 0, SEEK_SET);
    fwrite(&hdr, sizeof(hdr), 1, fout);
    fclose(fout);

    free(buf);
    clip.Close();
    return 0;
}

// ============================================================
// Argument helpers
// ============================================================

static int parseMaxDim(int argc, char* argv[], int from) {
    for (int i = from; i < argc - 1; i++)
        if (strcmp(argv[i], "--max-dim") == 0)
            return atoi(argv[i + 1]);
    return 512;
}

// ============================================================
// main
// ============================================================

int main(int argc, char* argv[]) {
    if (argc < 2) {
        fprintf(stderr,
            "Usage: r3d-tool <command> [args...]\n\n"
            "Commands:\n"
            "  probe <file>\n"
            "  extract-frame <file> <time> <out.jpg> [--max-dim N]\n"
            "  extract-frames <file> <times_json> <outdir> [--max-dim N]\n"
            "  extract-audio <file> <out.wav>\n");
        return 1;
    }

    // Initialize R3D SDK
    auto is = R3DSDK::InitializeSdk(getDylibPath(), OPTION_RED_NONE);
    if (is != R3DSDK::ISInitializeOK) {
        fprintf(stderr, "Error: R3D SDK init failed (status=%d, path=%s)\n",
                (int)is, getDylibPath());
        R3DSDK::FinalizeSdk();
        return 1;
    }

    int r = 1;
    const char* cmd = argv[1];

    if (strcmp(cmd, "probe") == 0 && argc >= 3)
        r = cmd_probe(argv[2]);
    else if (strcmp(cmd, "extract-frame") == 0 && argc >= 5)
        r = cmd_extract_frame(argv[2], atof(argv[3]), argv[4],
                               parseMaxDim(argc, argv, 5));
    else if (strcmp(cmd, "extract-frames") == 0 && argc >= 5)
        r = cmd_extract_frames(argv[2], argv[3], argv[4],
                                parseMaxDim(argc, argv, 5));
    else if (strcmp(cmd, "extract-audio") == 0 && argc >= 4)
        r = cmd_extract_audio(argv[2], argv[3]);
    else {
        fprintf(stderr, "Unknown or incomplete command: %s\n", cmd);
        r = 1;
    }

    R3DSDK::FinalizeSdk();
    return r;
}
