// promptfoo prompt function for the conversation coach. Reads the committed coach.txt
// the app uses and builds the same user message ConversationCoach.aiInsight builds, so
// the eval grades the real prompt (the suggested reply is written in the language the
// other person is speaking, and only when the other party spoke).
const fs = require('fs');
const path = require('path');

module.exports = async function ({ vars }) {
  const system = fs.readFileSync(
    path.join(__dirname, '..', 'Sources', 'MaiCore', 'Prompts', 'coach.txt'),
    'utf8'
  );
  const whoSpoke = String(vars.who_spoke || 'the other party');
  const user =
    'Interface language: ' + String(vars.interface || 'English') + '\n' +
    'Spoken language: ' + String(vars.spoken || 'English') + '\n' +
    'Speaker: ' + String(vars.speaker || 'Sato') + '\n' +
    'Who spoke: ' + whoSpoke + '\n' +
    'Suggested reply requested: ' + String(vars.reply_requested || 'yes') + '\n' +
    'Current utterance:\n' +
    String(vars.utterance || '') + '\n\n' +
    'Vocal feature summary from local PCM analysis:\n' +
    String(vars.vocal || 'pace=moderate pause_ratio=0.31 energy_trend=-0.04 pitch_mean=172Hz') + '\n\n' +
    'Recent transcript context:\n' +
    String(vars.conversation || '') + '\n\n' +
    'Return the JSON now.';
  return [
    { role: 'system', content: system },
    { role: 'user', content: user },
  ];
};
