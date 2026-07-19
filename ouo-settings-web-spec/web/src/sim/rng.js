// Детерминированный ГПСЧ (§19 ТЗ). Один seed → одинаковое поведение симуляции.
// mulberry32 — компактный, быстрый, воспроизводимый.

export function makeRng(seed) {
  let a = (seed >>> 0) || 1;
  const next = () => {
    a |= 0; a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  return {
    // [0,1)
    next,
    // true с вероятностью p
    chance: (p) => next() < p,
    // целое [min, max]
    int: (min, max) => min + Math.floor(next() * (max - min + 1)),
    // случайный элемент массива
    pick: (arr) => arr[Math.floor(next() * arr.length)],
    // два разных элемента массива
    pickPair: (arr) => {
      if (arr.length < 2) return [arr[0], arr[0]];
      const i = Math.floor(next() * arr.length);
      let j = Math.floor(next() * (arr.length - 1));
      if (j >= i) j += 1;
      return [arr[i], arr[j]];
    }
  };
}

export function randomSeed() {
  return Math.floor(Math.random() * 100000);
}
