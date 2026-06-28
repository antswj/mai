// promptfoo prompt function for the lookup router. Reads the SAME committed template
// the engine uses (Sources/MaiCore/Prompts/router.txt), so the eval grades the real
// prompt, not a copy. Returns system rules + the routing task.
const fs = require('fs');
const path = require('path');

module.exports = async function ({ vars }) {
  const system = fs.readFileSync(
    path.join(__dirname, '..', 'Sources', 'MaiCore', 'Prompts', 'router.txt'),
    'utf8'
  );
  const user =
    'Interface language: ' + String(vars.interface || 'English') + '\n' +
    'What the user wondered about: "' + String(vars.topic || '') + '"\n' +
    'Recent conversation (for context, newest last):\n' +
    String(vars.conversation || '') + '\n' +
    'Produce the JSON now.';
  return [
    { role: 'system', content: system },
    { role: 'user', content: user },
  ];
};
