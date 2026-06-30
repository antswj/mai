// promptfoo prompt function for the responder. Reads the committed responder.txt the
// app uses and builds the same user message RichCardEnricher.fetchResponse builds, so
// the eval grades the real prompt (reply language follows the spoken language).
const fs = require('fs');
const path = require('path');

module.exports = async function ({ vars }) {
  const system = fs.readFileSync(
    path.join(__dirname, '..', 'Sources', 'MaiCore', 'Prompts', 'responder.txt'),
    'utf8'
  );
  const user =
    'Spoken language: ' + String(vars.spoken || 'English') + '\n' +
    'Interface language: ' + String(vars.interface || 'English') + '\n' +
    'Conversation context (newest last):\n' +
    String(vars.conversation || '') + '\n' +
    'On screen now:\n(nothing)\n' +
    'Produce the JSON now.';
  return [
    { role: 'system', content: system },
    { role: 'user', content: user },
  ];
};
