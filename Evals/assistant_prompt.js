// promptfoo prompt function for the meeting assistant. Reads the committed
// assistant.txt the app uses and builds the same user message AnthropicAssistant
// builds, so the eval grades the real prompt.
const fs = require('fs');
const path = require('path');

module.exports = async function ({ vars }) {
  const system = fs.readFileSync(
    path.join(__dirname, '..', 'Sources', 'MaiCore', 'Prompts', 'assistant.txt'),
    'utf8'
  );
  const user =
    'Interface language: ' + String(vars.interface || 'English') + '\n' +
    'Meeting transcript so far (lines marked "You" are the user\'s own speech):\n' +
    String(vars.transcript || '') + '\n\n' +
    'On screen now:\n(nothing)\n\n' +
    'Conversation so far:\n(this is the first message)\n' +
    'User: ' + String(vars.question || '') + '\n\n' +
    'Answer as the assistant now.';
  return [
    { role: 'system', content: system },
    { role: 'user', content: user },
  ];
};
