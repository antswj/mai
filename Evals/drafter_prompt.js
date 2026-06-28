// promptfoo prompt function for the drafter. Reads the committed drafter template
// the engine uses, so the eval grades the real prompt. Returns system + the task.
const fs = require('fs');
const path = require('path');

module.exports = async function ({ vars }) {
  const system = fs.readFileSync(
    path.join(__dirname, '..', 'Sources', 'MaiCore', 'Prompts', 'drafter.txt'),
    'utf8'
  );
  return [
    { role: 'system', content: system },
    { role: 'user', content: String(vars.task || '') },
  ];
};
