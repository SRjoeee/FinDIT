<div align="center">

# FindIt

**Natural language search for your video footage.**

Find the exact clip you need in seconds, not hours.

<!-- TODO: Add hero screenshot or GIF here -->
<!-- ![FindIt Hero](assets/hero.png) -->

[![macOS](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white)](https://swift.org)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

</div>

---

## The Problem

If you work with video, you know the pain. You shot 200 clips last week. Now you need "that sunset shot on the beach" for your edit. So you open Finder, scrub through thumbnails, open files one by one, skip around the timeline... 20 minutes later, you're still looking.

FindIt fixes this.

## What It Does

Type what you're looking for in plain language. FindIt searches across all your footage folders and shows you matching clips instantly.

<!-- TODO: Add search demo GIF here -->
<!-- ![Search Demo](assets/search-demo.gif) -->

- **"sunset on the beach"** finds your coastal golden hour shots
- **"two people talking in a coffee shop"** finds that interview B-roll
- **"someone running"** finds action shots with actual motion, not just a person standing

### How It Works

1. **Add your footage folders** - drag them in or use the folder picker
2. **FindIt indexes in the background** - scene detection, speech-to-text, visual analysis, all running locally
3. **Search naturally** - type what you need, get results ranked by relevance

<!-- TODO: Add workflow GIF or 3-panel screenshot here -->
<!-- ![Workflow](assets/workflow.png) -->

## Features

### Smart Search
Hybrid search engine combining full-text keyword matching with vector-based semantic understanding. Understands what your footage *looks like*, not just what tags you gave it.

### Fully Local
All processing happens on your Mac. Your footage never leaves your machine. No cloud APIs required for core functionality.

<!-- TODO: Add screenshot of indexing progress UI -->
<!-- ![Indexing](assets/indexing.png) -->

### Background Indexing
Indexes your footage while you work. Adaptive resource management keeps things quiet - it backs off when your CPU is busy with an export, and picks up speed when your machine is idle.

### Portable Libraries
Each footage folder stores its own index. Move a hard drive to another Mac, and the index travels with it. No re-indexing needed.

### Multi-Engine Analysis
- **Scene Detection** - automatically segments videos into meaningful clips
- **Speech-to-Text** - indexes dialogue and narration so you can search by what was said
- **Visual Analysis** - understands scene content, objects, actions, lighting, mood
- **Smart Transcription** - generates SRT files alongside your footage

### Professional Format Support
Works with the formats you actually use:
- H.264, H.265, ProRes (MOV/MP4)
- MKV, MXF, AVI, WebM, and more
- Blackmagic RAW support planned

## Demo

<div align="center">

https://github.com/SRjoeee/FinDIT/raw/main/assets/demo.mp4

</div>

## Requirements

- macOS 14 (Sonoma) or later
- Apple Silicon Mac recommended
- [FFmpeg](https://ffmpeg.org/) installed at `~/.local/bin/ffmpeg`

## Building from Source

```bash
# Clone the repository
git clone https://github.com/SRjoeee/FinDIT.git
cd FinDIT

# Build
swift build

# Run the app
swift run FindItApp

# Or use the CLI tool
swift run findit-cli --help
```

> **Note:** Full Xcode installation is required for building (Xcode Command Line Tools alone won't work, as the project depends on XCTest and SwiftUI frameworks).

## Project Structure

```
Sources/
  FindItCore/       Core library - search engine, indexing pipeline, database
  FindItApp/        macOS SwiftUI application
  FindItCLI/        Command-line interface for scripting and testing
Tests/
  FindItCoreTests/  500+ unit tests
docs/
  ARCHITECTURE.md   System architecture and database schema
  TECH_DECISIONS.md Technical decision records
  ROADMAP.md        Development roadmap
```

## Architecture

FindIt uses a dual-layer SQLite storage strategy:

- **Folder-level databases** live alongside your footage (portable, self-contained)
- **Global search index** aggregates everything for fast cross-library search

The indexing pipeline processes videos through multiple stages: scene detection, keyframe extraction, speech transcription, and visual analysis. Each stage writes to the folder-level database, which syncs to the global index.

For more details, see [ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Roadmap

See [ROADMAP.md](docs/ROADMAP.md) for the full development plan.

**Coming soon:**
- NLE export (FCPXML, EDL) for Final Cut Pro and DaVinci Resolve
- Drag-and-drop clips directly into your editor
- Chinese language search support
- CLIP-based visual semantic search
- Photo and audio file support

## Contributing

This project is in active development. Contributions are welcome!

If you're interested in contributing, the codebase is organized to be approachable:
- Each module has corresponding tests
- Protocol-based abstractions make it easy to add new capabilities
- The [ARCHITECTURE.md](docs/ARCHITECTURE.md) and [TECH_DECISIONS.md](docs/TECH_DECISIONS.md) docs explain the why behind design choices

## License

MIT License. See [LICENSE](LICENSE) for details.

---

<div align="center">

Built for filmmakers, by someone who got tired of scrubbing through footage.

</div>
