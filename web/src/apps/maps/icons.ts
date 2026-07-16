import {
    Car, Crosshair, DollarSign, Flag, Fuel, Heart, Home, MapPin,
    ShoppingCart, Skull, Star, Wrench,
} from 'lucide-react';
import type { LucideIcon } from 'lucide-react';

export const ICONS = {
    MapPin, Home, Star, Flag, Skull, DollarSign,
    Car, Crosshair, Heart, Wrench, ShoppingCart, Fuel,
} satisfies Record<string, LucideIcon>;

export type IconKey = keyof typeof ICONS;
export const ICON_KEYS = Object.keys(ICONS) as IconKey[];

export function iconFor(key: string): LucideIcon {
    return (ICONS as Record<string, LucideIcon>)[key] ?? MapPin;
}
