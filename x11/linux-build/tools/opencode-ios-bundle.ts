import fs from "fs"
import path from "path"
import { createSolidTransformPlugin } from "@opentui/solid/bun-plugin"

const dir = process.cwd()
const generated = await import(path.join(dir, "script/generate.ts"))
const pkg = await Bun.file(path.join(dir, "package.json")).json()
const plugin = createSolidTransformPlugin()

// @opentui/core resolves its native renderer at runtime by importing the
// platform package (`@opentui/core-darwin-arm64` on iOS Bun, which reports
// process.platform === "darwin" / arch "arm64") and dlopen()ing that module's
// default export as a filesystem path. Bundling the platform package pulls its
// dylib asset in as a JS chunk, so dlopen sees a JS file and fails on device;
// even shipped verbatim, the macOS dylib cannot load on iOS. Intercept the
// platform-package specifiers at bundle time and substitute a virtual module
// whose default export is the install path of our iOS-native OpenTUI dylib.
// The device path exists after install; `opencode --version` never imports this
// module, so a hardcoded path is safe.
const OPENTUI_IOS_DYLIB = "/var/jb/usr/libexec/opencode-js/libopentui.dylib"
const opentuiNativeAliasPlugin: import("bun").BunPlugin = {
  name: "opentui-native-ios-alias",
  setup(build) {
    const filter = /^@opentui\/core-(darwin|linux|win32)-/
    build.onResolve({ filter }, (args) => ({
      path: args.path,
      namespace: "opentui-ios-native",
    }))
    build.onLoad({ filter: /.*/, namespace: "opentui-ios-native" }, () => ({
      contents: `export default ${JSON.stringify(OPENTUI_IOS_DYLIB)};`,
      loader: "js",
    }))
  },
}
const outdir = path.join(dir, "dist/opencode-ios-js")

await Bun.$`rm -rf ${outdir}`
await Bun.$`mkdir -p ${outdir}`

const localPath = path.resolve(dir, "node_modules/@opentui/core/parser.worker.js")
const rootPath = path.resolve(dir, "../../node_modules/@opentui/core/parser.worker.js")
const parserWorker = fs.realpathSync(fs.existsSync(localPath) ? localPath : rootPath)
const workerPath = "./src/cli/tui/worker.ts"
const workerRelativePath = path.relative(dir, parserWorker).replaceAll("\\", "/")

// The TUI RPC transport (src/util/rpc.ts) runs opencode's core in a worker that
// the main thread reaches via `new Worker(OPENCODE_WORKER_PATH)`. Upstream bakes
// the source specifier "./src/cli/tui/worker.ts" here because their real build
// is a `bun build --compile` single-file exe with an embedded bunfs where that
// path resolves. We ship a plain multi-file Bun bundle instead: the worker entry
// is emitted as .js (not .ts), the .ts source is not shipped, and `new Worker`
// is called AFTER process.chdir() into the user's project -- so a relative
// specifier resolves against the wrong base. The worker then fails with
// ModuleNotFound, is terminated, and the first `client.call("fetch")` throws on
// postMessage to the dead worker. Bake the absolute install path of the compiled
// worker instead (same fixed-path approach as the OpenTUI dylib alias); it is
// robust to chdir and needs no import.meta resolution.
const OPENCODE_WORKER_INSTALL_PATH = "/var/jb/usr/libexec/opencode-js/src/cli/tui/worker.js"

const result = await Bun.build({
  conditions: ["bun", "node"],
  tsconfig: "./tsconfig.json",
  plugins: [plugin, opentuiNativeAliasPlugin],
  external: ["node-gyp"],
  format: "esm",
  minify: true,
  sourcemap: "none",
  splitting: true,
  outdir,
  target: "bun",
  entrypoints: ["./src/index.ts", parserWorker, workerPath],
  define: {
    FFF_LIBC: JSON.stringify("gnu"),
    OPENCODE_VERSION: JSON.stringify(pkg.version),
    OPENCODE_MODELS_DEV: generated.modelsData,
    OTUI_TREE_SITTER_WORKER_PATH: `/${workerRelativePath}`,
    OPENCODE_WORKER_PATH: OPENCODE_WORKER_INSTALL_PATH,
    OPENCODE_CHANNEL: JSON.stringify("latest"),
    OPENCODE_LIBC: "",
  },
})

if (!result.success) {
  console.error(result.logs)
  process.exit(1)
}

// web-tree-sitter (its CORE runtime and every grammar) is imported as
//   `import wasm from "./chunk-XXXX.js" with { type: "wasm" }`
// where each chunk-XXXX.js is a stub whose default export is the relative path
// of the real .wasm asset (e.g. `var t="./tree-sitter-<hash>.wasm";export{t as
// default}`). In upstream's `bun build --compile` single-file exe the embedded
// bunfs resolves that indirection. In our plain multi-file bundle it does NOT:
// an `import ... with { type: "wasm" }` of a JS chunk makes Bun hand back the
// STUB CHUNK'S OWN path as the value, not the stub's exported string. shell.ts
// (packages/opencode/src/tool/shell.ts parses bash/PowerShell with tree-sitter)
// then passes that JS path to emscripten's locateFile, tree-sitter tries to
// compile "// @bun..." as WebAssembly, and every shell/edit tool call aborts
// with "WebAssembly.Module doesn't parse at byte 0: module doesn't start with
// '\0asm'". Verified on-device: the resolved core path was a chunk-*.js.
// Fix: overwrite each wasm-stub chunk's contents with the raw bytes of the
// .wasm it references, so the `type: "wasm"` import lands on a file that IS
// valid wasm. Detect stubs by shape (a lone default-exported "*.wasm" string)
// so it survives grammar/version churn. Covers the core runtime and all
// grammars; photon uses its own explicit __OPENCODE_PHOTON_WASM_PATH and is
// unaffected.
const WASM_STUB_RE =
  /(?:var|let|const)\s+\w+\s*=\s*["'](?:\.\/)?([^"']+\.wasm)["']\s*;?\s*export\s*\{\s*\w+\s+as\s+default\s*\}/
let wasmStubsPatched = 0
for (const output of result.outputs) {
  if (!output.path.endsWith(".js")) continue
  const match = fs.readFileSync(output.path, "utf8").match(WASM_STUB_RE)
  if (!match) continue
  const wasmPath = path.join(outdir, path.basename(match[1]))
  if (!fs.existsSync(wasmPath)) {
    console.error(`wasm-stub ${path.basename(output.path)} references missing ${match[1]}`)
    process.exit(1)
  }
  const bytes = fs.readFileSync(wasmPath)
  const magicOk = bytes.length >= 4 && bytes[0] === 0x00 && bytes[1] === 0x61 && bytes[2] === 0x73 && bytes[3] === 0x6d
  if (!magicOk) {
    console.error(`wasm-stub target ${path.basename(wasmPath)} is not valid wasm (bad \\0asm magic)`)
    process.exit(1)
  }
  fs.copyFileSync(wasmPath, output.path)
  wasmStubsPatched++
  console.log(`wasm-stub ${path.basename(output.path)} <- ${path.basename(wasmPath)} (${bytes.length} bytes)`)
}
if (wasmStubsPatched === 0) {
  console.error("no web-tree-sitter wasm-stub chunks found to patch (expected >= 1)")
  process.exit(1)
}

console.log(result.outputs.map((output) => path.relative(outdir, output.path)).join("\n"))
console.log(`patched ${wasmStubsPatched} wasm-stub chunk(s)`)
