// The positive control for contrast check 10's coverage comparator.
// Hunt part 2, R51: the control took its victim from the panels declared unwalked, so it
// could only run while coverage debt existed and failed the day coverage was complete. It now
// falls back to a panel that IS walked: forget that it was reached and declared, and the
// comparator must name exactly that panel.
"use strict";

function coverageControl(panels, reached, declaredUnwalked) {
  const victim = panels.find((id) => !reached.has(id)) || panels[0];
  const reachedCopy = new Set(reached.keys());
  reachedCopy.delete(victim);
  const declaredCopy = new Map(declaredUnwalked);
  declaredCopy.delete(victim);
  const named = panels.filter((id) => !reachedCopy.has(id) && !declaredCopy.has(id));
  return { victim, named };
}

module.exports = { coverageControl };
