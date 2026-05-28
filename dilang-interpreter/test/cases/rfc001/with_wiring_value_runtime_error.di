capability Logger { fn info(msg: Str) }

fn main() {
    let _w = with [ Logger <- StdoutLogger @ 'Process ]
}
