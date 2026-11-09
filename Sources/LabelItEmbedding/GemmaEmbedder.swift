// Adapted from DigUp's LlamaEmbedder (https://github.com/ARahim3/DigUp, MIT License, © 2026 Abdur Rahim; see ThirdPartyLicenses/DigUp-MIT.txt):
// the same input framing, batching and pooling, trimmed to text and images. Pictures come from the platform's reader
// (`Pixels`), so this runs wherever llama.cpp does.
import CLlama
import Foundation
import LabelItCore

public struct EmbeddingError: Error, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}

/// EmbeddingGemma 2 on llama.cpp (Metal), in this process. Text and images go into one 768-dimensional
/// space: an image's vector lands near the words that describe it. Vectors are mean-pooled and L2-normalized,
/// so a dot product is a cosine similarity.
///
/// Inputs are framed as the reference frames them: `<bos> text <eos>` and `<bos> <|image> soft tokens <image|> <eos>`.
/// Not thread-safe: use from one task at a time (`GemmaPhotoDescriber` does). About 1 GB while loaded.
final class GemmaEmbedder {
    /// Soft tokens per image. DigUp uses this for photos; more costs time without helping a short description.
    static let imageBudget = 280

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var media: OpaquePointer?
    private var batch: OpaquePointer?
    private let vocab: OpaquePointer?
    private let embeddingSize: Int
    private let rowSize: Int
    private let maxTokens = 2048
    private static let maxSequences = 16
    private var sequences: Int32 = 0
    private var tokens = 0
    private var position: llama_pos = 0

    init(files: ModelFiles.Located) throws {
        _ = Self.backend
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 999
        guard let model = llama_model_load_from_file(files.text.path, modelParams) else {
            throw EmbeddingError("can't load \(files.text.lastPathComponent)")
        }
        var params = llama_context_default_params()
        params.n_ctx = UInt32(maxTokens)
        params.n_batch = UInt32(maxTokens)
        params.n_ubatch = UInt32(maxTokens)
        params.n_seq_max = UInt32(Self.maxSequences)
        params.kv_unified = true
        params.embeddings = true
        params.pooling_type = LLAMA_POOLING_TYPE_MEAN
        guard let context = llama_init_from_model(model, params) else {
            llama_model_free(model)
            throw EmbeddingError("can't create a llama.cpp context")
        }
        var mediaParams = mtmd_context_params_default()
        mediaParams.use_gpu = true
        mediaParams.print_timings = false
        mediaParams.warmup = true
        mediaParams.image_min_tokens = 1   // images arrive at their final size (see `bitmap`)
        mediaParams.image_max_tokens = 1120
        guard let media = mtmd_init_from_file(files.media.path, model, mediaParams) else {
            llama_free(context)
            llama_model_free(model)
            throw EmbeddingError("can't load \(files.media.lastPathComponent)")
        }
        self.model = model
        self.context = context
        self.media = media
        batch = llama_batch_ext_init(context)
        vocab = llama_model_get_vocab(model)
        embeddingSize = Int(llama_model_n_embd_out(model))
        rowSize = Int(llama_model_n_embd_inp(model))
    }

    deinit { close() }

    func close() {
        if let batch { llama_batch_ext_free(batch) }
        if let media { mtmd_free(media) }
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        (batch, media, context, model) = (nil, nil, nil, nil)
    }

    // MARK: Text

    /// One vector per text, batched up to 16 at a time.
    func embed(texts: [String]) throws -> [[Float]] {
        reset()
        var vectors: [[Float]] = []
        for text in texts {
            let tokens = tokenize(text)
            if sequences == Self.maxSequences || self.tokens + tokens.count > maxTokens { vectors += try run() }
            begin()
            for token in tokens { try add(token: token) }
        }
        if sequences > 0 { vectors += try run() }
        return vectors
    }

    // MARK: Images

    func embed(image: any Pixels) throws -> [Float] {
        guard let media else { throw EmbeddingError("closed") }
        let bitmap = try Self.bitmap(from: image)
        defer { mtmd_bitmap_free(bitmap) }
        let chunks = mtmd_input_chunks_init()
        defer { mtmd_input_chunks_free(chunks) }
        var bitmaps: [OpaquePointer?] = [bitmap]
        let status = String(cString: mtmd_default_marker()).withCString { marker in
            var text = mtmd_input_text(text: marker, text_len: strlen(marker), add_special: true, parse_special: true)
            return mtmd_tokenize(media, chunks, &text, &bitmaps, 1)
        }
        guard status == 0 else { throw EmbeddingError("can't tokenize the image (\(status))") }
        reset()
        begin()
        for index in 0..<mtmd_input_chunks_size(chunks) {
            let chunk = mtmd_input_chunks_get(chunks, index)
            if mtmd_input_chunk_get_type(chunk) == MTMD_INPUT_CHUNK_TYPE_TEXT {
                var count = 0
                guard let tokens = mtmd_input_chunk_get_tokens_text(chunk, &count) else { continue }
                for i in 0..<count { try add(token: tokens[i]) }
            } else {
                guard mtmd_encode_chunk(media, chunk) == 0, let rows = mtmd_get_output_embd(media) else {
                    throw EmbeddingError("the image encoder failed")
                }
                try add(rows: rows, count: mtmd_input_chunk_get_n_tokens(chunk))
            }
        }
        return try run()[0]
    }

    /// Packed RGB at the size the reference processor would choose for the budget.
    private static func bitmap(from image: any Pixels) throws -> OpaquePointer {
        guard let target = targetSize(height: image.height, width: image.width, budget: imageBudget) else {
            throw EmbeddingError("image too small or too thin")
        }
        let (height, width) = target
        guard let rgb = image.rgb(width: width, height: height) else { throw EmbeddingError("can't draw the image") }
        guard let bitmap = mtmd_bitmap_init(UInt32(width), UInt32(height), rgb) else {
            throw EmbeddingError("can't make a bitmap")
        }
        return bitmap
    }

    /// transformers' Gemma image processor: fill `budget` soft tokens (each 3 × 3 patches of 16 px) keeping the
    /// aspect ratio, each side rounded down to a multiple of 48 px. (From DigUp's ImageSizing.)
    static func targetSize(height: Int, width: Int, budget: Int) -> (height: Int, width: Int)? {
        guard height > 0, width > 0 else { return nil }
        let patch = 16, pooling = 3
        let maxPatches = budget * pooling * pooling
        let factor = (Double(maxPatches * patch * patch) / Double(height * width)).squareRoot()
        let side = pooling * patch
        var targetHeight = Int((factor * Double(height) / Double(side)).rounded(.down)) * side
        var targetWidth = Int((factor * Double(width) / Double(side)).rounded(.down)) * side
        if targetHeight == 0 && targetWidth == 0 { return nil }
        let maxSide = (maxPatches / (pooling * pooling)) * side
        if targetHeight == 0 {
            targetHeight = side
            targetWidth = min(width / height * side, maxSide)
        } else if targetWidth == 0 {
            targetWidth = side
            targetHeight = min(height / width * side, maxSide)
        }
        return (targetHeight, targetWidth)
    }

    // MARK: Text model

    private func tokenize(_ text: String) -> [llama_token] {
        let utf8 = Array(text.utf8CString)
        var tokens = [llama_token](repeating: 0, count: utf8.count + 8)
        var count = llama_tokenize(vocab, utf8, Int32(utf8.count - 1), &tokens, Int32(tokens.count), true, true)
        if count < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-count))
            count = llama_tokenize(vocab, utf8, Int32(utf8.count - 1), &tokens, Int32(tokens.count), true, true)
        }
        tokens.removeLast(tokens.count - Int(max(count, 0)))
        if tokens.count > maxTokens {
            tokens = Array(tokens[0..<(maxTokens - 1)]) + [llama_vocab_eos(vocab)]
        }
        return tokens
    }

    private func begin() {
        sequences += 1
        position = 0
    }

    private func reset() {
        llama_batch_ext_clear(batch)
        sequences = 0
        tokens = 0
    }

    private func add(token: llama_token) throws {
        try place(llama_batch_ext_add_token(batch, sequences - 1, token))
    }

    private func add(rows: UnsafeMutablePointer<Float>, count: Int) throws {
        for row in 0..<count {
            let embd = llama_embd(data: rows + row * rowSize, n_rows: 1, n_embd: rowSize)
            try place(llama_batch_ext_add_embd(batch, sequences - 1, embd))
        }
    }

    private func place(_ index: Int32) throws {
        guard index >= 0 else { throw EmbeddingError("batch full (\(index))") }
        var pos: [llama_pos] = [position, 0, 0, 0]
        guard llama_batch_ext_set_pos(batch, index, &pos), llama_batch_ext_set_output_embd(batch, index, true) else {
            throw EmbeddingError("can't place token \(index)")
        }
        position += 1
        tokens += 1
    }

    private func run() throws -> [[Float]] {
        defer { reset() }
        let status = llama_process(context, LLAMA_PROCESS_TYPE_ENCODE, batch)
        guard status == 0 else { throw EmbeddingError("llama_process failed (\(status))") }
        return try (0..<sequences).map { sequence in
            guard let pooled = llama_get_embeddings_seq(context, sequence) else {
                throw EmbeddingError("no pooled embedding for input \(sequence)")
            }
            var sum = 0.0
            for i in 0..<embeddingSize { sum += Double(pooled[i]) * Double(pooled[i]) }
            let scale = sum > 0 ? Float(1 / sum.squareRoot()) : 0
            return (0..<embeddingSize).map { pooled[$0] * scale }
        }
    }

    /// llama.cpp's process-wide setup, once. Only its errors are shown: its warnings are about the model file's token
    /// list and mean nothing to someone renaming photos.
    private static let backend: Void = {
        llama_log_set({ level, text, _ in
            guard let text, level.rawValue >= GGML_LOG_LEVEL_ERROR.rawValue, level != GGML_LOG_LEVEL_CONT else { return }
            FileHandle.standardError.write(Data(("[llama.cpp] " + String(cString: text)).utf8))
        }, nil)
        mtmd_helper_log_set({ _, _, _ in }, nil)
        llama_backend_init()
    }()
}
