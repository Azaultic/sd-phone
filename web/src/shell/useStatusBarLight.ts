import { useEffect } from 'react';

import { useDeckActive } from '@/shell/deckActive';
import { useThemeStore } from '@/stores/themeStore';

export function useStatusBarLight(value: boolean | null): void {
    const active = useDeckActive();
    useEffect(() => {
        if (!active || value == null) return;
        useThemeStore.getState().setStatusLightOverride(value);
        return () => useThemeStore.getState().setStatusLightOverride(null);
    }, [active, value]);
}
