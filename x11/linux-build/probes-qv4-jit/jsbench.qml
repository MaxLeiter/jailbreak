// jsbench.qml: QV4 JIT vs interpreter. Run headless:
//   QT_QPA_PLATFORM=offscreen /var/jb/usr/bin/qml jsbench.qml            (JIT)
//   QV4_FORCE_INTERPRETER=1 QT_QPA_PLATFORM=offscreen /var/jb/usr/bin/qml jsbench.qml
// QV4 has no on-stack replacement: a function is JIT-compiled after QV4_JIT_CALL_THRESHOLD (3) interpreted
// calls, so every workload is a function called several times and the total is timed.
import QtQml

QtObject {
    function fib(n) { return n < 2 ? n : fib(n - 1) + fib(n - 2) }
    function propLoop() {
        var o = { a: 1, b: 2 }; var s = 0
        for (var i = 0; i < 300000; i++) { s += o.a + o.b + (i & 7); o.a = i & 3 }
        return s
    }
    function mathLoop() {
        var s = 0
        for (var i = 1; i < 200000; i++) s += Math.floor(i / 3) % 7 + (i * 0.5 | 0)
        return s
    }
    function arrays() {
        var a = []
        for (var i = 0; i < 20000; i++) a.push({ id: i, w: i % 13 })
        return a.filter(function (x) { return x.w > 5 }).map(function (x) { return x.id * 2 })
                .reduce(function (p, c) { return p + c }, 0)
    }
    function strings() {
        var arr = []
        for (var j = 0; j < 30000; j++) arr.push("x" + (j % 100))
        return arr.join(",").length
    }
    function regexps() {
        var re = /([a-z]+)-(\d+)/; var cnt = 0
        for (var k = 0; k < 20000; k++) { if (re.exec("abc-" + k)) cnt++ }
        return cnt
    }
    function time(name, f, reps) {
        var t0 = Date.now(); var r
        for (var i = 0; i < reps; i++) r = f()
        var dt = Date.now() - t0
        console.log("jsbench", name, dt, "ms (result " + r + ")")
        return dt
    }
    Component.onCompleted: {
        var total = 0
        total += time("fib(25)x6", function () { return fib(25) }, 6)
        total += time("propLoop x20", propLoop, 20)
        total += time("mathLoop x20", mathLoop, 20)
        total += time("arrays x20", arrays, 20)
        total += time("strings x10", strings, 10)
        total += time("regexp x10", regexps, 10)
        console.log("jsbench total", total, "ms")
        Qt.quit()
    }
}
