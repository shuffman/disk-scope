<!doctype html>
<html>
<head>
<title>404. Page Not Found</title>
<link href='http://fonts.googleapis.com/css?family=Roboto+Condensed:400,300|Roboto:400,300,100,100italic,400italic'
    rel='stylesheet' type='text/css'>
<style>
body {
    background: black;
    color: white;
    font-family: Roboto;
    font-weight: 100;
}
p {
    text-align: center;
    font-size: 2em;
}
td {
    width: 36px;
    height: 36px;
    line-height: 50px;
    text-align: center;
    background: #606060;
    color: white;
    position: relative;
    border-radius: 3px;
}
table {
    margin: 0 auto;
}
body.tilted table {
    transform-origin: 50% 50%;
    transform: rotateX(40deg);
    transform-style: preserve-3d;
    transition: transform 0.5s ease;
    backface-visibility: visible;
}
tbody {
    transform-style: preserve-3d;
}
tr {
    transform-style: preserve-3d;
    backface-visibility: visible;
}
div {
    perspective: 400px;
    transform-style: preserve-3d;
}
td {
    transform-style: preserve-3d;
}
b, span {
    position: absolute;
    padding: 0;
    margin: 0;
    top: 0;
    left: 0;
    right: 0;
    bottom: 0;
    background: transparent;
    width: 100%;
    height: 100%;
    transform-origin: 50% 0%;
    border-radius: 2px;
    box-shadow: 0 0 5px inset white;
    transition: transform 0.5s ease;
    transform-style: preserve-3d;
    backface-visibility: visible;
    background: rgba(0,128,0,0.55);
}
body.tilted td > b:nth-child(1) {
    transform: rotateX(90deg) translateY(100%) rotateX(-90deg);
}
body.tilted td > b:nth-child(2) {
    transform: rotateX(90deg) translateY(200%) rotateX(-90deg);
}
body.tilted td > b:nth-child(3) {
    transform: rotateX(90deg) translateY(300%) rotateX(-90deg);
}
body.tilted td > b:nth-child(4) {
    transform: rotateX(90deg) translateY(400%) rotateX(-90deg);
}
body.tilted td > b:nth-child(5) {
    transform: rotateX(90deg) translateY(500%) rotateX(-90deg);
}
body.tilted b > span:nth-child(1) {
    transform: rotateX(-90deg) translateY(100%);
    transform-origin: 0% 100%;
}
body.tilted b > span:nth-child(2) {
    transform: rotateX(-90deg) rotateY(90deg) translateY(100%);
    transform-origin: 0% 100%;
}
body.tilted b > span:nth-child(3) {
    transform: translateY(-100%) rotateX(-90deg) translateY(100%);
    transform-origin: 0% 100%;
}
body.tilted b > span:nth-child(4) {
    transform: rotateX(-90deg) rotateY(-90deg) translateY(100%);
    transform-origin: 100% 100%;
}
td:hover, b:hover, b:hover span {
    background: rgba(255, 255, 255, 0.6);
}
a {
    color: #dd4814;
    text-decoration: none;
}
</style>
</head>
<body>

<div>
<table>
</table>
<p>sorry you couldn't find what you want.</p>
<p>you can <a href="/">go home</a> and start from there.</p>
<script>
var tbl = document.querySelector("table"), rows = [],
    spans = "<b><span></span><span></span><span></span><span></span></b>",
    blocks = [
        0,2,11,12,13,24,4,5,6,15,17,26,27,28,8,10,19,20,21,32,
        44,45,46,55,57,66,68,48,49,50,59,61,70,71,72,52,53,54,64,75,
        88,89,90,99,100,110,92,93,94,103,105,114,116,96,97,107,109,118,119
    ];
for (var x=0; x<11; x++) {
    var row = [];
    for (var y=0; y<11; y++) {
        var box = "<td>";
        if (blocks.indexOf(x*11+y) != -1) { box += spans; }
        row.push(box + "</td>");
    }
    rows.push("<tr>" + row.join("") + "</tr>");
}
tbl.innerHTML = rows.join("\n");
var handler = function(t) {
    var tnn = t.nodeName.toLowerCase(), cube, cell;
    console.log("tnn", tnn);
    if (tnn == "span") {
        cube = t.parentNode;
        cell = cube.parentNode;
    } else if (tnn == "b") {
        cube = t;
        cell = cube.parentNode;
    } else if (tnn == "td") {
        cell = t;
    } else {
        console.log("unexpected click target", t);
        return;
    }

    document.body.className = "tilted";
    var action;
    if (cube && cube.nextSibling) {
        // a non-top cube
        action = "remove";
    } else if (cube && !cube.nextSibling && !cube.previousSibling) {
        // only 1 cube present; what to do depends on whether you clicked side or top
        if (tnn == "span") { // side
            action = "remove";
        } else {
            action = "add";
        }
    } else if (!cube || !cube.nextSibling) {
        // a top cube (including the "null" top cube where there are no cubes)
        if (cell.getElementsByTagName("b").length < 5) {
            action = "add";
        }
    } else {
        // shouldn't happen
    }

    if (action == "remove") {
        cube.parentNode.removeChild(cube);
    } else if (action == "add") {
        var newcube = document.createElement("b");
        newcube.appendChild(document.createElement("span"));
        newcube.appendChild(document.createElement("span"));
        newcube.appendChild(document.createElement("span"));
        newcube.appendChild(document.createElement("span"));
        cell.appendChild(newcube);
    }


    return;
    if (t.nodeName.toLowerCase() === "span" || t.nodeName.toLowerCase() === "td") {
        console.log("clicked");
        document.body.className = "tilted";



        var trg = t;
        if (trg.parentNode.nodeName.toLowerCase() === "span") {
            trg = trg.parentNode;
            console.log("p is span; new is", trg);
        }
        if (trg.parentNode.nodeName.toLowerCase() === "td") {
            console.log("p is td, trg is", trg);
            if (trg.nextSibling) {
                console.log("...has sibling");
                trg.parentNode.removeChild(trg);
            } else {
                console.log("...no sibling, add");
                var span = document.createElement("b");
                span.appendChild(document.createElement("span"));
                span.appendChild(document.createElement("span"));
                span.appendChild(document.createElement("span"));
                span.appendChild(document.createElement("span"));
                trg.parentNode.insertBefore(span, trg);
            }
        }
    }
}
tbl.addEventListener("click", function(e) {
    handler(e.target);
    e.preventDefault();
}, false);
tbl.addEventListener("touchstart", function(e) {
    handler(e.target);
    e.preventDefault();
}, false);
setTimeout(function() { document.body.className = "tilted" }, 5000);
</script>
</div>
</body>
</html>