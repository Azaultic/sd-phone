export const FIELD_W = 392;
export const FIELD_H = 600;

export const CHAR_W = 42;
export const CHAR_H = 46;

export const GRAVITY = 0.34;
export const BOUNCE_V = -12.6;
export const MAX_FALL = 15;
export const MOVE_SPEED = 4.6;

export const PLAT_W = 74;
export const PLAT_H = 16;
const PLAT_GAP_MIN = 64;
export const PLAT_GAP_MAX = 96;
export const MOVING_SPEED = 1.7;

export const SCROLL_LINE = FIELD_H * 0.42;

type PlatKind = 'static' | 'moving' | 'breakable';

export interface Platform {
    id: number;
    x: number;
    y: number;
    kind: PlatKind;
    dir: number;
    dead: boolean;
}

function pickKind(height: number): PlatKind {
    const r = Math.random();
    const breakChance = height > 60 ? 0.12 : 0;
    const moveChance = height > 25 ? 0.2 : 0.08;
    if (r < breakChance) return 'breakable';
    if (r < breakChance + moveChance) return 'moving';
    return 'static';
}

function randomPlatX(): number {
    return Math.random() * (FIELD_W - PLAT_W);
}

let idCounter = 1;
function nextPlatId(): number {
    idCounter += 1;
    return idCounter;
}

export function initialPlatforms(charX: number): Platform[] {
    const plats: Platform[] = [];
    plats.push({
        id: nextPlatId(),
        x: Math.max(0, Math.min(FIELD_W - PLAT_W, charX + CHAR_W / 2 - PLAT_W / 2)),
        y: FIELD_H - 70,
        kind: 'static',
        dir: 1,
        dead: false,
    });
    let y = FIELD_H - 70;
    while (y > -PLAT_GAP_MAX) {
        y -= PLAT_GAP_MIN + Math.random() * (PLAT_GAP_MAX - PLAT_GAP_MIN);
        plats.push({
            id: nextPlatId(),
            x: randomPlatX(),
            y,
            kind: 'static',
            dir: Math.random() < 0.5 ? -1 : 1,
            dead: false,
        });
    }
    return plats;
}

export function makePlatformAbove(topY: number, height: number): Platform {
    const gap = PLAT_GAP_MIN + Math.random() * (PLAT_GAP_MAX - PLAT_GAP_MIN);
    return {
        id: nextPlatId(),
        x: randomPlatX(),
        y: topY - gap,
        kind: pickKind(height),
        dir: Math.random() < 0.5 ? -1 : 1,
        dead: false,
    };
}

export function landsOn(
    prevBottom: number,
    bottom: number,
    charLeft: number,
    charRight: number,
    p: Platform,
): boolean {
    if (p.dead) return false;
    const platTop = p.y;
    const overlapX = charRight > p.x + 4 && charLeft < p.x + PLAT_W - 4;
    if (!overlapX) return false;
    return prevBottom <= platTop + 1 && bottom >= platTop && bottom <= platTop + PLAT_H + 14;
}
