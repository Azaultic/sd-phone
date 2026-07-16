import { isFiveM } from '@/core/nui';
import { apiData } from '@/core/api';


export interface MapsUiConfig {
    people: boolean;
}

let cached: MapsUiConfig | null = null;

export async function mapsConfig(): Promise<MapsUiConfig> {
    if (cached) return cached;
    if (!isFiveM) { cached = { people: true }; return cached; }
    const r = await apiData<{ people?: boolean }>('sd-phone:maps:config');
    cached = { people: r?.people !== false };
    return cached;
}
