"""A representative Jac module exercising the breadth of the grammar.

Used by CI to lint the highlight/locals/folds/injections queries against a
real parse tree (every node/field they reference must exist).
"""

import os;
import from typing { Optional }
import from .utils { helper as h }

glob registry: dict = {};

obj:pub Person {
    has name: str;
    has age: int = 0;
    has tags: list[str] = [];

    def greet(other: str) -> str {
        return f"Hi {other}, I am {self.name}";
    }
}

impl Person.birthday {
    self.age += 1;
}

node City {
    has name: str;
}

edge Road {
    has dist: int;
}

walker Tour {
    has visited: list = [];

    can start with entry {
        here.visited.append(here.name);
        visit [-->][?:City];
    }

    can finish with Root exit;
}

enum Status {
    ACTIVE = 1,
    DONE = 2
}

def transform(items: list) -> list {
    evens = [i for i in items if i % 2 == 0];
    pairs = {k: v for k, v in enumerate(items)};
    total = sum(x for x in evens);
    fn = lambda (a: int, b: int) -> int { return a + b; };
    return [fn(e, total) for e in evens];
}

with entry {
    p = Person(name="Ada");
    label = p.greet("world") if p.age > 0 else "n/a";
    result = data |> clean :> normalize;
    match label {
        case "n/a": print("missing");
        case _: print(label);
    }
}

def render(items: list) -> any {
    return
        <div class="panel" style={{"pad": 8}}>
            <Header onClose={handleClose}/>
            <ul>{items}</ul>
            <Footer.Bar {stats}/>
            Total items shown above.
        </div>;
}

edge Follows: any --> any {
    has since: int = 0;
}

obj Shape {
    has area_cache: float postinit;
    has radius: float {
        getter -> float;
    }
    def area -> float abst;
}

def borrow(w: &mut World, r: imm Region) -> int {
    a: own Buffer = Buffer();
    count = (a as Sized).size;
    for i = 0 while i < count with i += 1 {
        use(i);
    }
    flow for v in &items {
        use(v);
    }
    #* block comments
       span lines *#
    return count;
}

def view -> JsxElement {
    has open: bool = False;
    <div>
        {if open {
            <p>open</p>;
        }}
    </div>
}
