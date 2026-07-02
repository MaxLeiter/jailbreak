import fs from "fs"
import path from "path"
import { createSolidTransformPlugin } from "@opentui/solid/bun-plugin"

const dir = process.cwd()
const generated = await import(path.join(dir, "script/generate.ts"))
const pkg = await Bun.file(path.join(dir, "package.json")).json()
const plugin = createSolidTransformPlugin()
const outdir = path.join(dir, "dist/opencode-ios-js")

await Bun.$`rm -rf ${outdir}`
await Bun.$`mkdir -p ${outdir}`

const localPath = path.resolve(dir, "node_modules/@opentui/core/parser.worker.js")
const rootPath = path.resolve(dir, "../../node_modules/@opentui/core/parser.worker.js")
const parserWorker = fs.realpathSync(fs.existsSync(localPath) ? localPath : rootPath)
const workerPath = "./src/cli/tui/worker.ts"
const workerRelativePath = path.relative(dir, parserWorker).replaceAll("\\", "/")

const result = await Bun.build({
  conditions: ["bun", "node"],
  tsconfig: "./tsconfig.json",
  plugins: [plugin],
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
    OPENCODE_WORKER_PATH: workerPath,
    OPENCODE_CHANNEL: JSON.stringify("latest"),
    OPENCODE_LIBC: "",
  },
})

if (!result.success) {
  console.error(result.logs)
  process.exit(1)
}

console.log(result.outputs.map((output) => path.relative(outdir, output.path)).join("\n"))
