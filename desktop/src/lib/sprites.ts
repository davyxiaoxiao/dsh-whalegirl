import down from "@assets/pet_down.png";
import fall from "@assets/pet_fall.png";
import fallB from "@assets/pet_fall_b.png";
import getup from "@assets/pet_getup.png";
import heldA from "@assets/pet_held_a.png";
import heldB from "@assets/pet_held_b.png";
import idle from "@assets/pet_idle.png";
import panic from "@assets/pet_panic.png";
import smugA from "@assets/pet_smug_a.png";
import smugB from "@assets/pet_smug_b.png";
import walkA from "@assets/pet_walk_a.png";
import walkB from "@assets/pet_walk_b.png";
import walkC from "@assets/pet_walk_c.png";
import work from "@assets/pet_work.png";
import workB from "@assets/pet_work_b.png";
import workC from "@assets/pet_work_c.png";

export const SPRITES: Record<string, string> = {
  pet_idle: idle,
  pet_work: work,
  pet_work_b: workB,
  pet_work_c: workC,
  pet_smug_a: smugA,
  pet_smug_b: smugB,
  pet_panic: panic,
  pet_walk_a: walkA,
  pet_walk_b: walkB,
  pet_walk_c: walkC,
  pet_held_a: heldA,
  pet_held_b: heldB,
  pet_fall: fall,
  pet_fall_b: fallB,
  pet_down: down,
  pet_getup: getup,
};

let preloaded = false;
export function preloadSprites() {
  if (preloaded) return;
  preloaded = true;
  for (const src of Object.values(SPRITES)) {
    const image = new Image();
    image.src = src;
  }
}
