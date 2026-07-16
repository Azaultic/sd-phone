import {
    CloudDrizzle, CloudFog, CloudLightning, CloudRain, CloudSnow, Cloud,
    Cloudy, Snowflake, Sun, Wind,
} from 'lucide-react';
import type { ComponentProps } from 'react';

import type { WeatherCode } from './data';

const ICONS: Record<WeatherCode, typeof Sun> = {
    EXTRASUNNY: Sun,
    CLEAR:      Sun,
    NEUTRAL:    Sun,
    CLEARING:   Sun,
    CLOUDS:     Cloud,
    SMOG:       Cloudy,
    FOGGY:      CloudFog,
    OVERCAST:   Cloudy,
    RAIN:       CloudRain,
    THUNDER:    CloudLightning,
    SNOWLIGHT:  CloudSnow,
    SNOW:       CloudSnow,
    BLIZZARD:   Snowflake,
    XMAS:       Snowflake,
    HALLOWEEN:  Wind,
};

const TINTS: Record<WeatherCode, string> = {
    EXTRASUNNY: '#ffd60a',
    CLEAR:      '#ffd60a',
    NEUTRAL:    '#fefae0',
    CLEARING:   '#fefae0',
    CLOUDS:     '#e5e7eb',
    SMOG:       '#cbd5d3',
    FOGGY:      '#dbe1e6',
    OVERCAST:   '#9ca3af',
    RAIN:       '#7dd3fc',
    THUNDER:    '#a78bfa',
    SNOWLIGHT:  '#ffffff',
    SNOW:       '#ffffff',
    BLIZZARD:   '#ffffff',
    XMAS:       '#fee2e2',
    HALLOWEEN:  '#fb923c',
};

interface Props extends Omit<ComponentProps<typeof Sun>, 'color'> {
    code: WeatherCode;
}

void CloudDrizzle;

export function WeatherIcon({ code, ...rest }: Props) {
    const Icon = ICONS[code];
    return <Icon {...rest} color={TINTS[code]} />;
}
