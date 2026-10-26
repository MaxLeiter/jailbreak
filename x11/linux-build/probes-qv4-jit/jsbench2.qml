// jsbench2.qml: pure-JS workloads (no QML scope lookups). Same invocation as jsbench.qml.
import QtQml
QtObject {
    Component.onCompleted: {
        function fib(n) { return n < 2 ? n : fib(n - 1) + fib(n - 2) }
        function loop() { var s = 0; for (var i = 0; i < 1000000; i++) { s = (s + i * 3) & 0xffff } return s }
        var t0 = Date.now(); var r = 0
        for (var k = 0; k < 6; k++) r += fib(25)
        var t1 = Date.now()
        for (var j = 0; j < 10; j++) r += loop()
        var t2 = Date.now()
        console.log("jsbench2 localfib", t1 - t0, "ms loop", t2 - t1, "ms", r)
        Qt.quit()
    }
}
