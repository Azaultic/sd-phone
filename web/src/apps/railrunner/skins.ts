
type SkinKind = 'color' | 'character';
type SkinVariant = 'classic' | 'robot' | 'ninja' | 'astronaut' | 'alien';

interface SkinColors {
    body: string;
    bodyLight: string;
    arm: string;
    legA: string;
    legB: string;
    head: string;
    cap: string;
    capDark: string;
    eye: string;
    accent?: string;
}

export interface Skin {
    id: string;
    name: string;
    kind: SkinKind;
    cost: number;
    variant: SkinVariant;
    colors: SkinColors;
}

const LEGS_DARK = { legA: '#2E3550', legB: '#3A4368' };

export const SKINS: Skin[] = [
    {
        id: 'classic', name: 'Classic', kind: 'color', cost: 0, variant: 'classic',
        colors: { body: '#FF7A3C', bodyLight: '#FF9A5E', arm: '#E8632B', ...LEGS_DARK, head: '#FFD9B0', cap: '#1E66D0', capDark: '#1452A8', eye: '#23303A' },
    },
    {
        id: 'teal', name: 'Teal', kind: 'color', cost: 150, variant: 'classic',
        colors: { body: '#16B8A6', bodyLight: '#3FD6C4', arm: '#0E8C7E', ...LEGS_DARK, head: '#FFD9B0', cap: '#0E6B62', capDark: '#094A44', eye: '#23303A' },
    },
    {
        id: 'crimson', name: 'Crimson', kind: 'color', cost: 150, variant: 'classic',
        colors: { body: '#D7443B', bodyLight: '#F26A60', arm: '#A8261F', ...LEGS_DARK, head: '#FFD9B0', cap: '#5A1410', capDark: '#3A0C09', eye: '#23303A' },
    },
    {
        id: 'gold', name: 'Gold', kind: 'color', cost: 350, variant: 'classic',
        colors: { body: '#F2B705', bodyLight: '#FFD23E', arm: '#C28A00', ...LEGS_DARK, head: '#FFD9B0', cap: '#6B5200', capDark: '#4A3800', eye: '#23303A' },
    },
    {
        id: 'neon', name: 'Neon', kind: 'color', cost: 500, variant: 'classic',
        colors: { body: '#39E08A', bodyLight: '#7CFFB0', arm: '#1FA862', ...LEGS_DARK, head: '#FFD9B0', cap: '#0E3D26', capDark: '#082A19', eye: '#23303A' },
    },
    {
        id: 'robot', name: 'Robot', kind: 'character', cost: 700, variant: 'robot',
        colors: { body: '#9AA7B8', bodyLight: '#C2CCD8', arm: '#6E7B8C', legA: '#4A5260', legB: '#5A6473', head: '#B8C2D0', cap: '#6E7B8C', capDark: '#4A5260', eye: '#2BE0FF', accent: '#2BE0FF' },
    },
    {
        id: 'ninja', name: 'Ninja', kind: 'character', cost: 900, variant: 'ninja',
        colors: { body: '#2E3550', bodyLight: '#404A6B', arm: '#1C2030', legA: '#1C2030', legB: '#232838', head: '#1C2030', cap: '#1C2030', capDark: '#11131F', eye: '#FFFFFF', accent: '#D7443B' },
    },
    {
        id: 'astronaut', name: 'Astronaut', kind: 'character', cost: 1200, variant: 'astronaut',
        colors: { body: '#ECEFF5', bodyLight: '#FFFFFF', arm: '#C7CEDA', legA: '#C7CEDA', legB: '#B4BCCB', head: '#FFD9B0', cap: '#ECEFF5', capDark: '#C7CEDA', eye: '#23303A', accent: '#BFE6FF' },
    },
    {
        id: 'alien', name: 'Alien', kind: 'character', cost: 1500, variant: 'alien',
        colors: { body: '#16B8A6', bodyLight: '#3FD6C4', arm: '#0E8C7E', ...LEGS_DARK, head: '#8BE85A', cap: '#0E6B62', capDark: '#094A44', eye: '#14201A', accent: '#8BE85A' },
    },
];

export const DEFAULT_SKIN = 'classic';

const BY_ID: Record<string, Skin> = Object.fromEntries(SKINS.map((s) => [s.id, s]));

export function getSkin(id: string | undefined): Skin {
    return (id && BY_ID[id]) || BY_ID[DEFAULT_SKIN];
}
