// test-model-validation.swift — Unit tests for ModelValidator (Core.swift).
// PURE PARSERS ONLY — no network. Hand-crafted JSON fixtures mirror the real
// Hugging Face / OpenAI / Anthropic response shapes.
//
// Compile and run WITH Core.swift:
//   swiftc -o /tmp/test-model-validation tests/test-model-validation.swift scripts/Core.swift && /tmp/test-model-validation

import Foundation

// MARK: - Test Harness

var passCount = 0
var failCount = 0

func assert(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    if condition {
        passCount += 1
    } else {
        failCount += 1
        print("  FAIL [\(file):\(line)]: \(message)")
    }
}

func test(_ name: String, _ body: () -> Void) {
    print("  Running: \(name)")
    body()
}

func data(_ s: String) -> Data { s.data(using: .utf8)! }

// MARK: - Fixtures (representative shapes from the real APIs)

// A valid, PUBLIC GGUF repo: top-level `gguf` object present, not private, not gated.
let hfValidGGUF = """
{
  "_id": "abc123",
  "id": "Qwen/Qwen2.5-7B-Instruct-GGUF",
  "modelId": "Qwen/Qwen2.5-7B-Instruct-GGUF",
  "private": false,
  "gated": false,
  "downloads": 12345,
  "likes": 678,
  "gguf": {
    "total": 7615616000,
    "architecture": "qwen2",
    "context_length": 32768
  },
  "siblings": [
    {"rfilename": "qwen2.5-7b-instruct-q4_k_m.gguf"}
  ]
}
"""

// A GATED repo (gated == "manual"): is a GGUF repo but needs token + accepted terms.
let hfGatedManual = """
{
  "id": "meta-llama/Llama-3.1-8B-Instruct-GGUF",
  "private": false,
  "gated": "manual",
  "gguf": { "total": 4920000000, "architecture": "llama" }
}
"""

// An "auto" gate — still needs a token, treated as needs-token.
let hfGatedAuto = """
{
  "id": "some/auto-gated-GGUF",
  "private": false,
  "gated": "auto",
  "gguf": { "total": 1000000000 }
}
"""

// A PRIVATE GGUF repo — needs a token.
let hfPrivateGGUF = """
{
  "id": "me/private-GGUF",
  "private": true,
  "gated": false,
  "gguf": { "total": 2000000000 }
}
"""

// A repo that exists but is NOT a GGUF repo (no top-level `gguf` object).
let hfNonGGUF = """
{
  "id": "Qwen/Qwen2.5-7B-Instruct",
  "private": false,
  "gated": false,
  "pipeline_tag": "text-generation",
  "siblings": [
    {"rfilename": "model-00001-of-00004.safetensors"},
    {"rfilename": "config.json"}
  ]
}
"""

// A tree listing (`/tree/main`) with multiple quants + non-GGUF files mixed in.
// GGUFs stored via LFS expose the real size under `lfs.size`.
let hfTree = """
[
  {"type": "file", "oid": "a1", "size": 1576, "path": "README.md"},
  {"type": "file", "oid": "a2", "size": 800, "path": "config.json"},
  {"type": "file", "oid": "b1", "size": 135,
   "path": "Qwen2.5-7B-Instruct-Q4_K_M.gguf",
   "lfs": {"oid": "deadbeef", "size": 4683073088, "pointerSize": 135}},
  {"type": "file", "oid": "b2", "size": 135,
   "path": "Qwen2.5-7B-Instruct-Q8_0.gguf",
   "lfs": {"oid": "cafef00d", "size": 8098524672, "pointerSize": 135}},
  {"type": "file", "oid": "b3", "size": 135,
   "path": "Qwen2.5-7B-Instruct-IQ4_XS.gguf",
   "lfs": {"oid": "12345678", "size": 4218492416, "pointerSize": 135}}
]
"""

// OpenAI-compatible /v1/models body.
let openAIModels = """
{
  "object": "list",
  "data": [
    {"id": "gpt-4o", "object": "model", "owned_by": "openai"},
    {"id": "gpt-4o-mini", "object": "model", "owned_by": "openai"},
    {"id": "o1", "object": "model", "owned_by": "openai"}
  ]
}
"""

// Anthropic /v1/models body (has display_name; we still extract id).
let anthropicModels = """
{
  "data": [
    {"type": "model", "id": "claude-opus-4-5-20251101", "display_name": "Claude Opus 4.5"},
    {"type": "model", "id": "claude-sonnet-4-5-20250514", "display_name": "Claude Sonnet 4.5"},
    {"type": "model", "id": "claude-3-5-haiku-20241022", "display_name": "Claude Haiku 3.5"}
  ],
  "has_more": false,
  "first_id": "claude-opus-4-5-20251101"
}
"""

// MARK: - Tests

print("ModelValidator tests")
print("========================================")

// --- HF model parser ---

test("Valid public GGUF repo → state .valid") {
    let info = ModelValidator.parseHFModel(data(hfValidGGUF))
    assert(info != nil, "parsed")
    assert(info?.hasGGUF == true, "has gguf object")
    assert(info?.isPrivate == false, "not private")
    assert(info?.gated == HFGated.none, "not gated")
    let v = ModelValidator.validateHFModel(status: 200, info: info)
    assert(v.state == .valid, "should be valid, got \(v.state)")
    assert(v.isUsable, "usable")
}

test("Gated 'manual' GGUF repo → validNeedsToken") {
    let info = ModelValidator.parseHFModel(data(hfGatedManual))
    assert(info?.hasGGUF == true, "has gguf")
    assert(info?.gated == HFGated.manual, "gated manual")
    let v = ModelValidator.validateHFModel(status: 200, info: info)
    assert(v.state == .validNeedsToken, "needs token, got \(v.state)")
    assert(!v.isUsable, "not directly usable without token")
}

test("Gated 'auto' GGUF repo → validNeedsToken") {
    let info = ModelValidator.parseHFModel(data(hfGatedAuto))
    assert(info?.gated == HFGated.auto, "gated auto")
    let v = ModelValidator.validateHFModel(status: 200, info: info)
    assert(v.state == .validNeedsToken, "needs token, got \(v.state)")
}

test("Private GGUF repo → validNeedsToken") {
    let info = ModelValidator.parseHFModel(data(hfPrivateGGUF))
    assert(info?.isPrivate == true, "private")
    let v = ModelValidator.validateHFModel(status: 200, info: info)
    assert(v.state == .validNeedsToken, "needs token, got \(v.state)")
}

test("Non-GGUF repo → notGGUF") {
    let info = ModelValidator.parseHFModel(data(hfNonGGUF))
    assert(info?.hasGGUF == false, "no gguf object")
    let v = ModelValidator.validateHFModel(status: 200, info: info)
    assert(v.state == .notGGUF, "not a GGUF repo, got \(v.state)")
}

test("401/404 → notFound (anon HF returns 401 for nonexistent)") {
    let v401 = ModelValidator.validateHFModel(status: 401, info: nil)
    assert(v401.state == .notFound, "401 → notFound")
    let v404 = ModelValidator.validateHFModel(status: 404, info: nil)
    assert(v404.state == .notFound, "404 → notFound")
}

test("Garbage body → parseHFModel returns nil") {
    assert(ModelValidator.parseHFModel(data("not json")) == nil, "nil on garbage")
    let v = ModelValidator.validateHFModel(status: 200, info: nil)
    if case .error = v.state {} else { assert(false, "200 with nil info should be .error") }
}

// --- Quant parsing ---

test("parseQuant from filenames") {
    assert(ModelValidator.parseQuant(fromFilename: "Qwen2.5-7B-Instruct-Q4_K_M.gguf") == "Q4_K_M", "Q4_K_M")
    assert(ModelValidator.parseQuant(fromFilename: "model-IQ4_XS.gguf") == "IQ4_XS", "IQ4_XS")
    assert(ModelValidator.parseQuant(fromFilename: "model-Q8_0.gguf") == "Q8_0", "Q8_0")
    assert(ModelValidator.parseQuant(fromFilename: "model-Q5_K_S.gguf") == "Q5_K_S", "Q5_K_S")
    assert(ModelValidator.parseQuant(fromFilename: "llama-2-7b.Q4_0.gguf") == "Q4_0", "dotted Q4_0")
    assert(ModelValidator.parseQuant(fromFilename: "model-f16.gguf") == "F16", "F16")
    assert(ModelValidator.parseQuant(fromFilename: "model.gguf").isEmpty, "no quant → empty")
}

// --- HF tree parser ---

test("parseHFTree → only GGUFs, correct quant + LFS size, sorted") {
    let files = ModelValidator.parseHFTree(data(hfTree))
    assert(files.count == 3, "3 gguf files (README/config excluded), got \(files.count)")
    // Sorted by filename: IQ4_XS, Q4_K_M, Q8_0
    assert(files[0].filename == "Qwen2.5-7B-Instruct-IQ4_XS.gguf", "first sorted")
    assert(files[0].quant == "IQ4_XS", "IQ4_XS quant")
    assert(files[0].sizeBytes == 4218492416, "IQ4_XS LFS size")

    let q4 = files.first { $0.quant == "Q4_K_M" }
    assert(q4 != nil, "has Q4_K_M")
    assert(q4?.sizeBytes == 4683073088, "Q4_K_M LFS size, got \(q4?.sizeBytes ?? -1)")

    let q8 = files.first { $0.quant == "Q8_0" }
    assert(q8?.sizeBytes == 8098524672, "Q8_0 LFS size")
}

test("humanReadableSize formatting") {
    assert(Int64(4683073088).humanReadableSize == "4.7 GB", "4.7 GB, got \(Int64(4683073088).humanReadableSize)")
    assert(Int64(512_000_000).humanReadableSize == "512.0 MB", "512 MB, got \(Int64(512_000_000).humanReadableSize)")
}

// --- Cloud model parsers ---

test("parseOpenAIModels → ids") {
    let ids = ModelValidator.parseOpenAIModels(data(openAIModels))
    assert(ids == ["gpt-4o", "gpt-4o-mini", "o1"], "ids: \(ids)")
}

test("parseAnthropicModels → ids (display_name ignored)") {
    let ids = ModelValidator.parseAnthropicModels(data(anthropicModels))
    assert(ids == ["claude-opus-4-5-20251101", "claude-sonnet-4-5-20250514", "claude-3-5-haiku-20241022"],
           "anthropic ids: \(ids)")
}

test("cloud parsers tolerate garbage → empty") {
    assert(ModelValidator.parseOpenAIModels(data("nope")).isEmpty, "openai garbage empty")
    assert(ModelValidator.parseAnthropicModels(data("{}")).isEmpty, "anthropic missing data empty")
}

// --- Repo normalization ---

test("normalizeHFRepo strips URL/suffix") {
    assert(ModelValidator.normalizeHFRepo("  Qwen/Qwen2.5-7B-Instruct-GGUF  ") == "Qwen/Qwen2.5-7B-Instruct-GGUF", "trim")
    assert(ModelValidator.normalizeHFRepo("https://huggingface.co/Qwen/Qwen2.5-7B-Instruct-GGUF") == "Qwen/Qwen2.5-7B-Instruct-GGUF", "url strip")
    assert(ModelValidator.normalizeHFRepo("Qwen/Qwen2.5-7B-Instruct-GGUF:Q4_K_M") == "Qwen/Qwen2.5-7B-Instruct-GGUF", "quant suffix strip")
    assert(ModelValidator.normalizeHFRepo("https://huggingface.co/Qwen/Qwen2.5-7B-Instruct-GGUF/tree/main") == "Qwen/Qwen2.5-7B-Instruct-GGUF", "tree tail strip")
    // Regression: a URL's scheme colon (https:) must NOT be treated as a :quant suffix.
    assert(ModelValidator.normalizeHFRepo("Qwen/Repo:Q4_K_M") == "Qwen/Repo", "bare repo:quant → owner/name")
    assert(ModelValidator.normalizeHFRepo("https://huggingface.co/Qwen/Repo") == "Qwen/Repo", "pasted URL not mangled by scheme colon")
    assert(ModelValidator.normalizeHFRepo("http://huggingface.co/Owner/My-Repo-GGUF/resolve/main/x.gguf") == "Owner/My-Repo-GGUF", "resolve URL tail dropped, scheme intact")
}

test("safeGGUFFilename rejects unsafe names") {
    assert(ModelValidator.safeGGUFFilename("Qwen2.5-7B-Instruct-Q4_K_M.gguf") == "Qwen2.5-7B-Instruct-Q4_K_M.gguf", "plain ok")
    assert(ModelValidator.safeGGUFFilename("../../etc/passwd.gguf") == nil, "path traversal rejected")
    assert(ModelValidator.safeGGUFFilename("evil</string><x>.gguf") == nil, "xml injection rejected")
    assert(ModelValidator.safeGGUFFilename("has space.gguf") == nil, "space rejected")
    assert(ModelValidator.safeGGUFFilename("model.bin") == nil, "non-gguf rejected")
    assert(ModelValidator.safeGGUFFilename(".gguf") == nil, "empty stem rejected")
    assert(ModelValidator.safeGGUFFilename("name&co.gguf") == nil, "ampersand rejected")
}

test("hfResolveURL builds resolve link") {
    let u = ModelValidator.hfResolveURL(repo: "Qwen/X-GGUF", file: "x-Q4_K_M.gguf")
    assert(u == "https://huggingface.co/Qwen/X-GGUF/resolve/main/x-Q4_K_M.gguf", "resolve url: \(u)")
}

test("CloudProvider base URLs + mapping") {
    assert(CloudProvider.openai.defaultBaseURL == "https://api.openai.com", "openai base")
    assert(CloudProvider.gemini.defaultBaseURL.contains("generativelanguage"), "gemini base")
    assert(CloudProvider.anthropic.llmProviderRawValue == "claude", "anthropic→claude")
    assert(CloudProvider.gemini.llmProviderRawValue == "openai", "gemini→openai-compatible")
}

// MARK: - Results

print("\n========================================")
print("Results: \(passCount) passed, \(failCount) failed")
print("========================================")

if failCount > 0 {
    exit(1)
} else {
    print("All model-validation tests passed!")
    exit(0)
}
