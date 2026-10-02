// Correctness under tiering. A JIT that is merely fast is not working -- these
// run hot enough to reach DFG, then check answers against values computed while
// still cold, and deliberately provoke the paths most likely to break a fresh
// port: OSR exit on type change, GC while JIT code is live, inline-cache
// repatching (which on this device means writes through the W^X alias), and
// exception unwinding out of optimised frames.
let failures = 0;
function check(name, got, want) {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  if (!ok) { console.log(`FAIL ${name}: got ${JSON.stringify(got)} want ${JSON.stringify(want)}`); failures++; }
  return ok;
}

// 1. Same function, cold result vs hot result. Any tier-up miscompile shows here.
function poly(a, b, c) { return (a * b + c / 3) | 0; }
const coldPoly = [];
for (let i = 0; i < 20; i++) coldPoly.push(poly(i, i + 1, i + 2));
for (let i = 0; i < 2_000_000; i++) poly(i, i + 1, i + 2);
const hotPoly = [];
for (let i = 0; i < 20; i++) hotPoly.push(poly(i, i + 1, i + 2));
check("tier-up stability", hotPoly, coldPoly);

// 2. OSR exit: run int-only until DFG specialises, then feed it a double and a
//    string and make sure it bails out correctly instead of returning garbage.
function add(a, b) { return a + b; }
for (let i = 0; i < 1_000_000; i++) add(i, 1);
check("osr exit to double", add(1.5, 2.25), 3.75);
check("osr exit to string", add("a", "b"), "ab");
check("osr exit back to int", add(2, 3), 5);

// 3. Inline caches: a megamorphic call site repatches constantly, which is the
//    heaviest user of the JIT-memory write path.
const shapes = [];
for (let i = 0; i < 40; i++) { const o = {}; o["k" + i] = i; o.get = function () { return this["k" + i]; }; shapes.push(o); }
let icAcc = 0;
for (let i = 0; i < 400_000; i++) icAcc += shapes[i % shapes.length].get();
check("megamorphic ic", icAcc, (() => { let s = 0; for (let i = 0; i < 400_000; i++) s += i % 40; return s; })());

// 4. GC pressure while optimised code is on the stack.
function allocHot(n) {
  let last = null, sum = 0;
  for (let i = 0; i < n; i++) { last = { i, pad: [i, i + 1, i + 2], s: "x".repeat(i % 32) }; sum += last.i + last.pad[2]; }
  return sum;
}
check("gc under jit", allocHot(1_500_000), (() => { let s = 0; for (let i = 0; i < 1_500_000; i++) s += i + i + 2; return s; })());

// 5. Exceptions thrown out of hot frames.
function mayThrow(i) { if (i % 100_000 === 99_999) throw new Error("boom " + i); return i * 2; }
let caught = 0, esum = 0;
for (let i = 0; i < 1_000_000; i++) { try { esum += mayThrow(i); } catch { caught++; } }
check("exception unwind count", caught, 10);

// 6. Closures, generators, async -- different entry paths into JIT code.
function makeCounter() { let n = 0; return () => ++n; }
const c = makeCounter();
for (let i = 0; i < 500_000; i++) c();
check("closure state", c(), 500_001);

function* gen(n) { for (let i = 0; i < n; i++) yield i * i; }
let gsum = 0;
for (let i = 0; i < 50; i++) for (const v of gen(2000)) gsum += v;
check("generator sum", gsum, 50 * (() => { let s = 0; for (let i = 0; i < 2000; i++) s += i * i; return s; })());

// 7. Regex and JSON, which have their own compiled paths (YARR).
const re = /(\w+)@(\w+)\.com/;
let rmatches = 0;
for (let i = 0; i < 200_000; i++) if (re.test(`user${i}@example.com`)) rmatches++;
check("regex matches", rmatches, 200_000);

let jsonOk = true;
for (let i = 0; i < 100_000; i++) {
  const o = { a: i, b: [i, i + 1], c: { d: "s" + i } };
  if (JSON.parse(JSON.stringify(o)).c.d !== "s" + i) { jsonOk = false; break; }
}
check("json roundtrip", jsonOk, true);

// 8. Typed arrays / math, where the DFG has the most aggressive specialisations.
const ta = new Float64Array(4096);
for (let i = 0; i < 4096; i++) ta[i] = Math.sin(i) * 1000;
let tsum = 0;
for (let r = 0; r < 400; r++) for (let i = 0; i < 4096; i++) tsum += ta[i] * 2;
const expect = (() => { let s = 0; for (let i = 0; i < 4096; i++) s += Math.sin(i) * 1000 * 2; return s * 400; })();
check("typed array math", Math.abs(tsum - expect) < 1e-6, true);

console.log(failures === 0 ? "ALL JIT CORRECTNESS CHECKS PASSED" : `${failures} CHECK(S) FAILED`);
process.exit(failures === 0 ? 0 : 1);
