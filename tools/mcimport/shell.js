// Where a column stops being scenery and starts being island.
//
// The baker stores only the VISIBLE SHELL of each column and lets the runtime
// return Stone for everything beneath it. This module owns that rule so the baker
// and the verification test can't drift apart: the test asserts exactly what the
// format promises — the shell is reproduced block for block, below it is solid.

const { ID } = require("./voxlids");

// Natural rock: material a player only ever sees as "the inside of the ground".
const ROCK = new Set([
  ID.Stone, ID.Andesite, ID.Diorite, ID.Granite, ID.Gravel, ID.Dirt, ID.CoarseDirt,
  ID.Clay, ID.Sand, ID.Sandstone, ID.RedSand, ID.RedSandstone, ID.Terracotta,
  ID.CoalOre, ID.IronOre, ID.CopperOre, ID.GoldOre, ID.DiamondOre, ID.EmeraldOre,
  ID.LapisOre, ID.RedstoneOre, ID.Podzol, ID.Mud,
  // The deep-rock family. These used to be folded into Stone; now that they have
  // their own ids they must still count as "the inside of the ground", or a column
  // would refuse to terminate and drag the whole world's Y range to bedrock.
  ID.Deepslate, ID.CobbledDeepslate, ID.Bedrock, ID.Tuff, ID.Calcite,
  ID.Basalt, ID.Blackstone, ID.Netherrack, ID.Obsidian,
]);

const ROCK_RUN = 4;   // this many consecutive rock blocks ends the shell
const DEEP_CAP = 24;  // ...or this far below the first rock, if caves keep interrupting

// `at(k)` returns the block id at absolute index k (ascending y). Returns the
// index of the LOWEST block still part of the shell.
function shellBottom(at, top, floor) {
  let bot = top, run = 0, firstRock = -1;
  for (let k = top; k >= floor; k--) {
    bot = k;
    const id = at(k);
    if (ROCK.has(id)) {
      if (firstRock < 0) firstRock = k;
      run++;
      if (run >= ROCK_RUN) break;
    } else {
      run = 0;
    }
    if (firstRock >= 0 && firstRock - k >= DEEP_CAP) break;
  }
  return bot;
}

module.exports = { ROCK, ROCK_RUN, DEEP_CAP, shellBottom };
