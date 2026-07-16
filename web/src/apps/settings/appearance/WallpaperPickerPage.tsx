import { useState } from 'react';
import { Check } from 'lucide-react';

import { t } from '@/i18n';
import { PHOTO_SOURCES } from '@/apps/photos/data';
import { useIosPush } from '@/hooks/useIosPush';
import { useTheme } from '@/stores/themeStore';
import { resolveWallpaper } from '@/shell/wallpapers';
import { NavBar } from '@/ui/NavBar';

const WALLPAPER_LABELS = [
    'Daybreak',          // bg3
    'Cotton Candy',      // bg4
    'Marble',            // bg5
    'Prism',             // bg6
    'Tidal',             // bg7
    'Spectrum',          // bg8
    'Halo',              // bg9
    'Deep Current',      // bg10
    'Eclipse',           // bg11
    'Ink Bloom',         // bg12
    'Lavender Mist',     // bg13
    'Seafoam',           // bg14
    'Tide Pool',         // bg15
    'Loop',              // bg16
    'Carnival',          // bg17
    'Oil Slick',         // bg18
    'Meadow',            // bg19
    'Onyx',              // bg20
    'Neon Loop',         // bg21
    'Ember',             // bg22
];

export function WallpaperPickerPage({ onBack }: { onBack: () => void }) {
    const { goBack, pageStyle } = useIosPush(onBack);
    const { wallpaper, setWallpaper } = useTheme('wallpaper', 'setWallpaper');
    const [selected, setSelected] = useState<string>(wallpaper);

    function apply(src: string) {
        setSelected(src);
        setWallpaper(src);
    }

    return (
        <div className="absolute inset-0 z-30 flex flex-col bg-[#d4d4d4] dark:bg-black" style={pageStyle}>
            <div className="h-11 shrink-0" aria-hidden />

            <NavBar
                backLabel={t('settings.wallpaper', 'Wallpaper')}
                onBack={goBack}
                title={t('settings.chooseWallpaper', 'Choose a Wallpaper')}
                hairline
            />

            <div className="flex-1 overflow-y-auto no-scrollbar px-4 py-5">
                <p className="mb-3 text-[13px] uppercase tracking-wider text-ios-gray">
                    {t('settings.suggestedWallpapers', 'Suggested Wallpapers')}
                </p>

                <div className="grid grid-cols-2 gap-3">
                    {PHOTO_SOURCES.map((src, i) => {
                        const isSelected = resolveWallpaper(selected) === src;
                        return (
                            <button
                                key={i}
                                type="button"
                                onClick={() => apply(src)}
                                className="relative overflow-hidden rounded-[14px] active:opacity-80"
                                style={{
                                    boxShadow: isSelected
                                        ? '0 0 0 3px #0A84FF'
                                        : '0 2px 8px rgba(0,0,0,0.18)',
                                }}
                            >
                                <img
                                    src={src}
                                    className="block aspect-[9/16] w-full object-cover"
                                    alt={WALLPAPER_LABELS[i] ?? t('settings.wallpaperNumbered', 'Wallpaper {n}', { n: i + 1 })}
                                    draggable={false}
                                />

                                <div className="absolute inset-x-0 bottom-0 h-14 bg-gradient-to-t from-black/60 to-transparent" />
                                <span className="absolute bottom-2.5 left-3 text-[12px] font-semibold text-white drop-shadow">
                                    {WALLPAPER_LABELS[i]}
                                </span>

                                {isSelected && (
                                    <div className="absolute right-2.5 top-2.5 flex h-6 w-6 items-center justify-center rounded-full bg-ios-blue shadow">
                                        <Check className="h-[13px] w-[13px] text-white" strokeWidth={3} />
                                    </div>
                                )}
                            </button>
                        );
                    })}
                </div>

                <p className="mt-5 text-center text-[13px] text-ios-gray">
                    {t('settings.tapWallpaperHint', 'Tap a wallpaper to apply it to both Lock Screen and Home Screen.')}
                </p>

                <div className="h-8" />
            </div>
        </div>
    );
}
