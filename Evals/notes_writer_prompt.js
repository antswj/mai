// promptfoo prompt function for the meeting notes writer. Reads the committed
// notes-writer.txt the app uses and builds the same user message NotesStore builds.
const fs = require('fs');
const path = require('path');

module.exports = async function ({ vars }) {
  const system = fs.readFileSync(
    path.join(__dirname, '..', 'Sources', 'MaiCore', 'Prompts', 'notes-writer.txt'),
    'utf8'
  );
  const user =
    'Interface language: ' + String(vars.interface || 'English') + '\n' +
    'Transcript (lines marked "You" are the user\'s own speech):\n' +
    String(vars.transcript || '') + '\n' +
    'Explicitly noted items:\n' + String(vars.noted || '(none)') + '\n' +
    'Produce the JSON now.';
  return [
    { role: 'system', content: system },
    { role: 'user', content: user },
  ];
};
