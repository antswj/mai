// promptfoo prompt function for the classifier. Reads the SAME committed template
// the engine uses (Sources/MaiCore/Prompts/classifier.txt), so the eval grades the
// real prompt, not a copy. Returns a chat array: system rules + the conversation.
const fs = require('fs');
const path = require('path');

module.exports = async function ({ vars }) {
  const system = fs.readFileSync(
    path.join(__dirname, '..', 'Sources', 'MaiCore', 'Prompts', 'classifier.txt'),
    'utf8'
  );
  const user =
    'Conversation window (oldest first):\n' +
    String(vars.conversation || '') +
    '\n\nReturn the JSON object now.';
  return [
    { role: 'system', content: system },
    { role: 'user', content: user },
  ];
};
