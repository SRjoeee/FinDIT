/*
 * braw-tool — Blackmagic RAW CLI decoder for FindIt
 *
 * Subcommands:
 *   probe <file>                              → JSON metadata
 *   extract-frame <file> <time> <out> [--max-dim N]
 *   extract-frames <file> <times_json> <outdir> [--max-dim N]
 *   extract-audio <file> <out.wav>
 *
 * Based on official BRAW SDK samples (ExtractFrame, ExtractAudio, ExtractMetadata).
 * MIT license per Blackmagic SDK terms.
 */

#include "BlackmagicRawAPI.h"

#include <iostream>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <string>
#include <vector>

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreServices/CoreServices.h>
#include <ImageIO/ImageIO.h>

// ─── SDK Library Path ────────────────────────────────────────────────────────

static const char* kSDKLibraryPath =
    "/Applications/Blackmagic RAW/Blackmagic RAW SDK/Mac/Libraries";

// ─── Helpers ─────────────────────────────────────────────────────────────────

static CFStringRef ToCFString(const char* str)
{
    return CFStringCreateWithCString(kCFAllocatorDefault, str, kCFStringEncodingUTF8);
}

static IBlackmagicRawFactory* CreateFactory()
{
    CFStringRef libPath = ToCFString(kSDKLibraryPath);
    IBlackmagicRawFactory* factory = CreateBlackmagicRawFactoryInstanceFromPath(libPath);
    CFRelease(libPath);
    return factory;
}

// Forward declaration
static bool WriteJPEG(const char* outputPath, uint32_t srcW, uint32_t srcH,
                      void* rgbaData, int maxDim);

// ─── Frame Extraction Callback ───────────────────────────────────────────────

struct FrameResult
{
    bool success = false;
    std::string errorMsg;
};

class FrameCallback : public IBlackmagicRawCallback
{
public:
    BlackmagicRawResourceFormat resourceFormat;
    BlackmagicRawResolutionScale resolutionScale;
    FrameResult result;

    // Output params — set before Submit
    const char* outputPath = nullptr;
    int maxDim = 512;

    FrameCallback(BlackmagicRawResourceFormat fmt, BlackmagicRawResolutionScale scale)
        : resourceFormat(fmt), resolutionScale(scale) {}

    void ReadComplete(IBlackmagicRawJob* readJob, HRESULT hr, IBlackmagicRawFrame* frame) override
    {
        if (hr != S_OK) { readJob->Release(); return; }

        frame->SetResourceFormat(resourceFormat);
        if (resolutionScale != blackmagicRawResolutionScaleFull)
            frame->SetResolutionScale(resolutionScale);

        IBlackmagicRawJob* decodeJob = nullptr;
        hr = frame->CreateJobDecodeAndProcessFrame(nullptr, nullptr, &decodeJob);
        if (hr == S_OK)
            hr = decodeJob->Submit();
        if (hr != S_OK)
        {
            if (decodeJob) decodeJob->Release();
            result.errorMsg = "decode job failed";
        }
        readJob->Release();
    }

    void ProcessComplete(IBlackmagicRawJob* job, HRESULT hr, IBlackmagicRawProcessedImage* img) override
    {
        uint32_t width = 0, height = 0, sizeBytes = 0;
        void* rawData = nullptr;

        if (hr == S_OK) hr = img->GetWidth(&width);
        if (hr == S_OK) hr = img->GetHeight(&height);
        if (hr == S_OK) hr = img->GetResourceSizeBytes(&sizeBytes);
        if (hr == S_OK) hr = img->GetResource(&rawData);

        if (hr == S_OK && rawData && outputPath)
        {
            // Write JPEG directly while data is still valid
            result.success = WriteJPEG(outputPath, width, height, rawData, maxDim);
            if (!result.success)
                result.errorMsg = "JPEG write failed";
        }
        else
        {
            result.errorMsg = "decode/process failed";
        }

        job->Release();
    }

    void DecodeComplete(IBlackmagicRawJob*, HRESULT) override {}
    void TrimProgress(IBlackmagicRawJob*, float) override {}
    void TrimComplete(IBlackmagicRawJob*, HRESULT) override {}
    void SidecarMetadataParseWarning(IBlackmagicRawClip*, CFStringRef, uint32_t, CFStringRef) override {}
    void SidecarMetadataParseError(IBlackmagicRawClip*, CFStringRef, uint32_t, CFStringRef) override {}
    void PreparePipelineComplete(void*, HRESULT) override {}

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID, LPVOID*) override { return E_NOTIMPL; }
    ULONG STDMETHODCALLTYPE AddRef() override { return 0; }
    ULONG STDMETHODCALLTYPE Release() override { return 0; }
};

// ─── Write JPEG with resize ─────────────────────────────────────────────────

static bool WriteJPEG(const char* outputPath, uint32_t srcW, uint32_t srcH,
                      void* rgbaData, int maxDim)
{
    // Calculate target size (scale short edge to maxDim)
    uint32_t dstW = srcW, dstH = srcH;
    if (maxDim > 0)
    {
        uint32_t shortEdge = (srcW < srcH) ? srcW : srcH;
        if (shortEdge > (uint32_t)maxDim)
        {
            double scale = (double)maxDim / shortEdge;
            dstW = (uint32_t)(srcW * scale);
            dstH = (uint32_t)(srcH * scale);
            // Round to even
            dstW = (dstW + 1) & ~1u;
            dstH = (dstH + 1) & ~1u;
        }
    }

    bool needsResize = (dstW != srcW || dstH != srcH);

    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGBitmapInfo bitmapInfo = kCGImageAlphaNoneSkipLast | kCGImageByteOrderDefault;

    // Source image
    uint32_t srcBytesPerRow = srcW * 4;
    CGDataProviderRef provider = CGDataProviderCreateWithData(nullptr, rgbaData,
                                                              srcBytesPerRow * srcH, nullptr);
    CGImageRef srcImage = CGImageCreate(srcW, srcH, 8, 32, srcBytesPerRow,
                                         colorSpace, bitmapInfo, provider,
                                         nullptr, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);

    CGImageRef finalImage = srcImage;

    // Resize if needed
    CGContextRef resizeCtx = nullptr;
    if (needsResize)
    {
        uint32_t dstBytesPerRow = dstW * 4;
        resizeCtx = CGBitmapContextCreate(nullptr, dstW, dstH, 8, dstBytesPerRow,
                                           colorSpace, bitmapInfo);
        if (resizeCtx)
        {
            CGContextSetInterpolationQuality(resizeCtx, kCGInterpolationHigh);
            CGContextDrawImage(resizeCtx, CGRectMake(0, 0, dstW, dstH), srcImage);
            finalImage = CGBitmapContextCreateImage(resizeCtx);
        }
    }

    // Write JPEG
    CFStringRef path = ToCFString(outputPath);
    CFURLRef url = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, path,
                                                  kCFURLPOSIXPathStyle, false);
    bool ok = false;
    if (url && finalImage)
    {
        // Use JPEG UTI string directly to avoid deprecation warning
        CFStringRef jpegUTI = CFSTR("public.jpeg");
        CGImageDestinationRef dest = CGImageDestinationCreateWithURL(url, jpegUTI, 1, nullptr);
        if (dest)
        {
            // JPEG quality 0.85
            CFStringRef keys[] = { kCGImageDestinationLossyCompressionQuality };
            double qualityVal = 0.85;
            CFNumberRef quality = CFNumberCreate(nullptr, kCFNumberFloat64Type, &qualityVal);
            CFTypeRef vals[] = { quality };
            CFDictionaryRef props = CFDictionaryCreate(nullptr,
                (const void**)keys, (const void**)vals, 1,
                &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

            CGImageDestinationAddImage(dest, finalImage, props);
            ok = CGImageDestinationFinalize(dest);

            CFRelease(props);
            CFRelease(quality);
            CFRelease(dest);
        }
    }

    if (url) CFRelease(url);
    CFRelease(path);
    if (needsResize && finalImage && finalImage != srcImage)
        CGImageRelease(finalImage);
    if (resizeCtx) CGContextRelease(resizeCtx);
    CGImageRelease(srcImage);
    CGColorSpaceRelease(colorSpace);

    return ok;
}

// ─── Subcommand: probe ───────────────────────────────────────────────────────

static int CmdProbe(const char* filePath)
{
    IBlackmagicRawFactory* factory = CreateFactory();
    if (!factory) { fprintf(stderr, "Failed to load BRAW SDK\n"); return 1; }

    IBlackmagicRaw* codec = nullptr;
    IBlackmagicRawClip* clip = nullptr;

    HRESULT hr = factory->CreateCodec(&codec);
    if (hr != S_OK) { fprintf(stderr, "Failed to create codec\n"); factory->Release(); return 1; }

    CFStringRef cfPath = ToCFString(filePath);
    hr = codec->OpenClip(cfPath, &clip);
    CFRelease(cfPath);
    if (hr != S_OK) { fprintf(stderr, "Failed to open clip\n"); codec->Release(); factory->Release(); return 1; }

    uint32_t width = 0, height = 0;
    float fps = 0;
    uint64_t frameCount = 0;
    clip->GetWidth(&width);
    clip->GetHeight(&height);
    clip->GetFrameRate(&fps);
    clip->GetFrameCount(&frameCount);

    double duration = (fps > 0) ? (double)frameCount / fps : 0;

    // Audio info
    IBlackmagicRawClipAudio* audio = nullptr;
    uint32_t audioChannels = 0, audioSampleRate = 0, audioBitDepth = 0;
    bool hasAudio = false;
    hr = clip->QueryInterface(IID_IBlackmagicRawClipAudio, (void**)&audio);
    if (hr == S_OK && audio)
    {
        audio->GetAudioChannelCount(&audioChannels);
        audio->GetAudioSampleRate(&audioSampleRate);
        audio->GetAudioBitDepth(&audioBitDepth);
        hasAudio = (audioChannels > 0);
        audio->Release();
    }

    // Output JSON
    printf("{\"width\":%u,\"height\":%u,\"fps\":%.4f,\"frameCount\":%llu,"
           "\"duration\":%.4f,\"codec\":\"braw\",\"hasAudio\":%s,"
           "\"audioChannels\":%u,\"audioSampleRate\":%u,\"audioBitDepth\":%u}\n",
           width, height, fps, (unsigned long long)frameCount,
           duration, hasAudio ? "true" : "false",
           audioChannels, audioSampleRate, audioBitDepth);

    clip->Release();
    codec->Release();
    factory->Release();
    return 0;
}

// ─── Extract single frame ────────────────────────────────────────────────────

static int ExtractOneFrame(IBlackmagicRaw* codec, IBlackmagicRawClip* clip,
                            float fps, double timeSec, const char* outputPath, int maxDim)
{
    uint64_t frameIndex = (uint64_t)(timeSec * fps);

    // Clamp to valid range
    uint64_t frameCount = 0;
    clip->GetFrameCount(&frameCount);
    if (frameCount > 0 && frameIndex >= frameCount)
        frameIndex = frameCount - 1;

    FrameCallback callback(blackmagicRawResourceFormatRGBAU8,
                            blackmagicRawResolutionScaleQuarter);
    callback.outputPath = outputPath;
    callback.maxDim = maxDim;

    HRESULT hr = codec->SetCallback(&callback);
    if (hr != S_OK) { fprintf(stderr, "Failed to set callback\n"); return 1; }

    IBlackmagicRawJob* readJob = nullptr;
    hr = clip->CreateJobReadFrame(frameIndex, &readJob);
    if (hr != S_OK) { fprintf(stderr, "Failed to create read job\n"); return 1; }

    hr = readJob->Submit();
    if (hr != S_OK) { readJob->Release(); fprintf(stderr, "Failed to submit job\n"); return 1; }

    codec->FlushJobs();

    // Clear callback reference before it goes out of scope
    codec->SetCallback(nullptr);

    if (!callback.result.success)
    {
        fprintf(stderr, "Frame decode failed at %.2fs (frame %llu): %s\n",
                timeSec, (unsigned long long)frameIndex,
                callback.result.errorMsg.c_str());
        return 1;
    }

    return 0;
}

// ─── Subcommand: extract-frame ───────────────────────────────────────────────

static int CmdExtractFrame(const char* filePath, double timeSec,
                            const char* outputPath, int maxDim)
{
    IBlackmagicRawFactory* factory = CreateFactory();
    if (!factory) { fprintf(stderr, "Failed to load BRAW SDK\n"); return 1; }

    IBlackmagicRaw* codec = nullptr;
    IBlackmagicRawClip* clip = nullptr;
    int ret = 1;

    HRESULT hr = factory->CreateCodec(&codec);
    if (hr != S_OK) { fprintf(stderr, "Failed to create codec\n"); goto cleanup; }

    {
        CFStringRef cfPath = ToCFString(filePath);
        hr = codec->OpenClip(cfPath, &clip);
        CFRelease(cfPath);
    }
    if (hr != S_OK) { fprintf(stderr, "Failed to open clip\n"); goto cleanup; }

    {
        float fps = 0;
        clip->GetFrameRate(&fps);
        ret = ExtractOneFrame(codec, clip, fps, timeSec, outputPath, maxDim);
    }

cleanup:
    if (clip) clip->Release();
    if (codec) codec->Release();
    factory->Release();
    return ret;
}

// ─── Subcommand: extract-frames (batch) ──────────────────────────────────────

// Minimal JSON array parser: "[1.5, 3.0, 7.2]" → vector<double>
static std::vector<double> ParseTimesJSON(const char* json)
{
    std::vector<double> times;
    const char* p = json;
    while (*p && *p != '[') p++;
    if (*p == '[') p++;

    while (*p)
    {
        while (*p && (*p == ' ' || *p == ',')) p++;
        if (*p == ']' || *p == '\0') break;

        char* end = nullptr;
        double val = strtod(p, &end);
        if (end > p)
        {
            times.push_back(val);
            p = end;
        }
        else
        {
            p++;
        }
    }
    return times;
}

static int CmdExtractFrames(const char* filePath, const char* timesJSON,
                             const char* outputDir, int maxDim)
{
    auto times = ParseTimesJSON(timesJSON);
    if (times.empty())
    {
        fprintf(stderr, "No times provided\n");
        return 1;
    }

    IBlackmagicRawFactory* factory = CreateFactory();
    if (!factory) { fprintf(stderr, "Failed to load BRAW SDK\n"); return 1; }

    IBlackmagicRaw* codec = nullptr;
    IBlackmagicRawClip* clip = nullptr;
    int ret = 0;

    HRESULT hr = factory->CreateCodec(&codec);
    if (hr != S_OK) { fprintf(stderr, "Failed to create codec\n"); ret = 1; goto cleanup; }

    {
        CFStringRef cfPath = ToCFString(filePath);
        hr = codec->OpenClip(cfPath, &clip);
        CFRelease(cfPath);
    }
    if (hr != S_OK) { fprintf(stderr, "Failed to open clip\n"); ret = 1; goto cleanup; }

    {
        float fps = 0;
        clip->GetFrameRate(&fps);

        // Output JSON array of paths
        printf("[");
        for (size_t i = 0; i < times.size(); i++)
        {
            char outPath[4096];
            snprintf(outPath, sizeof(outPath), "%s/frame_%04zu.jpg", outputDir, i);

            int frameRet = ExtractOneFrame(codec, clip, fps, times[i], outPath, maxDim);
            if (i > 0) printf(",");
            if (frameRet == 0)
                printf("\"%s\"", outPath);
            else
            {
                printf("null");
                fprintf(stderr, "Warning: failed frame at %.2fs\n", times[i]);
            }
        }
        printf("]\n");
    }

cleanup:
    if (clip) clip->Release();
    if (codec) codec->Release();
    factory->Release();
    return ret;
}

// ─── WAV Header ──────────────────────────────────────────────────────────────

#pragma pack(push, 1)
struct WavHeader
{
    char     riffHeader[4]  = {'R','I','F','F'};
    uint32_t wavContentSize = 0;
    char     waveHeader[4]  = {'W','A','V','E'};
    char     fmtHeader[4]   = {'f','m','t',' '};
    uint32_t fmtChunkSize   = 16;
    uint16_t audioFormat     = 1;  // PCM
    uint16_t channelCount    = 0;
    uint32_t sampleRate      = 0;
    uint32_t bytesPerSecond  = 0;
    uint16_t blockAlign      = 0;
    uint16_t bitDepth        = 0;
    char     dataHeader[4]  = {'d','a','t','a'};
    uint32_t dataBytes       = 0;
};
#pragma pack(pop)

// ─── Subcommand: extract-audio ───────────────────────────────────────────────

static int CmdExtractAudio(const char* filePath, const char* outputPath)
{
    IBlackmagicRawFactory* factory = CreateFactory();
    if (!factory) { fprintf(stderr, "Failed to load BRAW SDK\n"); return 1; }

    IBlackmagicRaw* codec = nullptr;
    IBlackmagicRawClip* clip = nullptr;
    IBlackmagicRawClipAudio* audio = nullptr;
    int ret = 1;

    HRESULT hr = factory->CreateCodec(&codec);
    if (hr != S_OK) { fprintf(stderr, "Failed to create codec\n"); goto cleanup; }

    {
        CFStringRef cfPath = ToCFString(filePath);
        hr = codec->OpenClip(cfPath, &clip);
        CFRelease(cfPath);
    }
    if (hr != S_OK) { fprintf(stderr, "Failed to open clip\n"); goto cleanup; }

    hr = clip->QueryInterface(IID_IBlackmagicRawClipAudio, (void**)&audio);
    if (hr != S_OK || !audio)
    {
        fprintf(stderr, "No audio track in clip\n");
        ret = 1;
        goto cleanup;
    }

    {
        uint64_t sampleCount = 0;
        uint32_t bitDepth = 0, channelCount = 0, sampleRate = 0;

        audio->GetAudioSampleCount(&sampleCount);
        audio->GetAudioBitDepth(&bitDepth);
        audio->GetAudioChannelCount(&channelCount);
        audio->GetAudioSampleRate(&sampleRate);

        if (sampleCount == 0 || channelCount == 0)
        {
            fprintf(stderr, "Empty audio track\n");
            ret = 1;
            goto cleanup;
        }

        uint64_t dataBytes = (sampleCount * channelCount * bitDepth) / 8;

        WavHeader hdr;
        hdr.channelCount    = (uint16_t)channelCount;
        hdr.sampleRate      = sampleRate;
        hdr.bytesPerSecond  = sampleRate * channelCount * bitDepth / 8;
        hdr.blockAlign      = (uint16_t)(channelCount * bitDepth / 8);
        hdr.bitDepth        = (uint16_t)bitDepth;
        hdr.dataBytes       = (uint32_t)dataBytes;
        hdr.wavContentSize  = 36 + (uint32_t)dataBytes;

        FILE* f = fopen(outputPath, "wb");
        if (!f) { fprintf(stderr, "Cannot create %s\n", outputPath); goto cleanup; }

        fwrite(&hdr, sizeof(WavHeader), 1, f);

        // Read audio in chunks
        static const uint32_t kMaxSamples = 48000;
        uint32_t bufSize = (kMaxSamples * channelCount * bitDepth) / 8;
        std::vector<int8_t> buffer(bufSize);

        uint64_t sampleIndex = 0;
        while (sampleIndex < sampleCount)
        {
            uint32_t samplesRead = 0, bytesRead = 0;
            hr = audio->GetAudioSamples((int64_t)sampleIndex, buffer.data(),
                                         bufSize, kMaxSamples, &samplesRead, &bytesRead);
            if (hr != S_OK || samplesRead == 0) break;

            fwrite(buffer.data(), bytesRead, 1, f);
            sampleIndex += samplesRead;
        }

        fclose(f);

        // Output metadata JSON to stdout
        printf("{\"sampleRate\":%u,\"channels\":%u,\"bitDepth\":%u,"
               "\"samples\":%llu,\"outputPath\":\"%s\"}\n",
               sampleRate, channelCount, bitDepth,
               (unsigned long long)sampleCount, outputPath);
        ret = 0;
    }

cleanup:
    if (audio) audio->Release();
    if (clip) clip->Release();
    if (codec) codec->Release();
    factory->Release();
    return ret;
}

// ─── Usage ───────────────────────────────────────────────────────────────────

static void PrintUsage(const char* prog)
{
    fprintf(stderr,
        "Usage:\n"
        "  %s probe <file>\n"
        "  %s extract-frame <file> <time_sec> <output.jpg> [--max-dim N]\n"
        "  %s extract-frames <file> <times_json> <output_dir> [--max-dim N]\n"
        "  %s extract-audio <file> <output.wav>\n",
        prog, prog, prog, prog);
}

// ─── Main ────────────────────────────────────────────────────────────────────

int main(int argc, const char* argv[])
{
    if (argc < 3) { PrintUsage(argv[0]); return 1; }

    const char* cmd = argv[1];

    // Parse optional --max-dim from end of args
    int maxDim = 512;  // default
    int effectiveArgc = argc;
    for (int i = 3; i < argc - 1; i++)
    {
        if (strcmp(argv[i], "--max-dim") == 0)
        {
            maxDim = atoi(argv[i + 1]);
            effectiveArgc = i;
            break;
        }
    }

    if (strcmp(cmd, "probe") == 0 && effectiveArgc >= 3)
    {
        return CmdProbe(argv[2]);
    }
    else if (strcmp(cmd, "extract-frame") == 0 && effectiveArgc >= 5)
    {
        double timeSec = atof(argv[3]);
        return CmdExtractFrame(argv[2], timeSec, argv[4], maxDim);
    }
    else if (strcmp(cmd, "extract-frames") == 0 && effectiveArgc >= 5)
    {
        return CmdExtractFrames(argv[2], argv[3], argv[4], maxDim);
    }
    else if (strcmp(cmd, "extract-audio") == 0 && effectiveArgc >= 4)
    {
        return CmdExtractAudio(argv[2], argv[3]);
    }
    else
    {
        PrintUsage(argv[0]);
        return 1;
    }
}
