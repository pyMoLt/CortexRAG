# Changelog

All notable changes to **CortexRAG** are documented in this file.

## [1.0.0] – 2026-11-09

### Added
- **Multimodal Hybrid Search**: Local 768-dimensional Matryoshka text and image embeddings via **Google EmbeddingGemma 2** (`llama.cpp` Metal Q8_0 and **MLX Swift**), fused with SQLite FTS5 BM25 keyword search using Reciprocal Rank Fusion (RRF).
- **Apple Vision Figure Pipeline**: Automatic detection, cropping, deduplication, and PDF text-layer caption extraction for textbook figures, lecture slides, charts, and tables.
- **Hierarchical Library & Folder Tree**: Organize documents by Area (*Bereich*), Topic (*Thema*), and watched folders while keeping original PDFs in place on disk.
- **Instant Peek & Built-in PDF Reader**: Space-bar preview modal and full PDF reader with multi-line passage highlighting, outline browser, and extracted figure thumbnails.
- **Cited AI Synthesis & Multi-Turn Follow-Ups**: Streaming answers with clickable `[1]`, `[2]` passage citations, math/LaTeX/HTML rendering, prompt KV-cache reuse across follow-up questions, and local/remote server profiles (`oMLX`, `LM Studio`, `Ollama`) with automatic failover.
- **Optional Cross-Encoder Reranking**: Built-in lexical cross-scorer plus one-click download for `bge-reranker-v2-m3` and `Qwen3-Reranker-0.6B` (GGUF Q8_0 on Metal).
- **CLI & MCP Server (`cortexrag-cli`)**: Embedded command-line tool and `stdio` JSON-RPC 2.0 MCP server exposing library browsing, token-budgeted knowledge search, figure search, on-demand page figure cropping, and base64 multimodal image blocks.
- **Smart Power & Memory Management**: Configurable AC/battery indexing throttle modes (*Turbo*, *Balanced*, *Minimal*), Low Power Mode auto-pause, and automatic idle GPU memory unloading.
- **Bilingual Interface**: Full English and German localization with customizable accent colors and light/dark appearance.
