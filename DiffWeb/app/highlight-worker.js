import hljs from 'highlight.js'

var langMapping = {
  m: 'objc'
};

function languageForFilename(filename) {
  var a = filename.split('.');
  var ext = "";
  if (a.length > 1) ext = a[a.length-1];
  var lang = ext;
  if (lang in langMapping) lang = langMapping[lang];
  if (hljs.getLanguage(lang)) return lang;
  return null;
}

function splitLines(text) {
  return text.split(/\r\n|\r|\n/);
}

function splitHighlight(html) {
  var lines = splitLines(html);
  var stack = [];
  return lines.map((line) => {
    var newLine = line;
    if (stack.length) {
      newLine = stack.join("") + line;
    }
    var tags = line.match(/(<span.*?>)|(<\/span>)/g);
    if (tags) {
      tags.forEach((tag) => {
        if (tag.startsWith("</")) {
          stack.pop();
        } else {
          stack.push(tag);
        }
      });
    }
    for (var i = 0; i < stack.length; i++) {
      newLine += "</span>";
    }
    return newLine;
  });
}

onmessage = function(event) {
  var leftText = event.data.leftText;
  var rightText = event.data.rightText;
  var filename = event.data.filename;
  var language = languageForFilename(filename);
  
  var leftHighlighted = "";
  var rightHighlighted = "";
  if (language) {
    leftHighlighted = splitHighlight(hljs.highlight(language, leftText, true).value);
    rightHighlighted = splitHighlight(hljs.highlight(language, rightText, true).value);
  } else {
    leftHighlighted = splitHighlight(hljs.highlightAuto(leftText).value);
    rightHighlighted = splitHighlight(hljs.highlightAuto(rightText).value);
  }
  postMessage({leftHighlighted, rightHighlighted});
}