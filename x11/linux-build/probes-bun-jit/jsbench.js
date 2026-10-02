// Tiny tiering benchmark: each of these is something the baseline JIT and DFG
// should crush relative to LLInt, so the ratio between builds is the signal.
function fib(n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }

function loopSum(n) {
  let s = 0;
  for (let i = 0; i < n; i++) s = (s + i * 3) % 1000003;
  return s;
}

function strWork(n) {
  let h = 0;
  const s = "the quick brown fox jumps over the lazy dog";
  for (let i = 0; i < n; i++) h = (h * 31 + s.charCodeAt(i % s.length)) | 0;
  return h;
}

function objWork(n) {
  let acc = 0;
  for (let i = 0; i < n; i++) {
    const o = { a: i, b: i * 2, c: { d: i - 1 } };
    acc += o.a + o.b + o.c.d;
  }
  return acc;
}

function time(name, fn) {
  const t0 = performance.now();
  const v = fn();
  const ms = performance.now() - t0;
  console.log(`${name.padEnd(10)} ${ms.toFixed(1).padStart(9)} ms   (${v})`);
  return ms;
}

console.log(`bun ${Bun.version} on ${process.platform}/${process.arch}`);
let total = 0;
total += time("fib(30)", () => fib(30));
total += time("loopSum", () => loopSum(20_000_000));
total += time("strWork", () => strWork(10_000_000));
total += time("objWork", () => objWork(5_000_000));
console.log(`TOTAL      ${total.toFixed(1).padStart(9)} ms`);
