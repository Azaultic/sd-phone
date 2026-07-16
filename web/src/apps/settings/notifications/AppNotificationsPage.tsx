import { useState } from 'react';
import { Check, ChevronRight } from 'lucide-react';

import { t } from '@/i18n';
import { AppIconSVG } from '@/shell/AppIconSVG';
import { Toggle } from '@/ui/Toggle';
import { useIosPush } from '@/hooks/useIosPush';
import { useNuiQuery } from '@/hooks/useNuiQuery';
import { NavBar } from '@/ui/NavBar';
import { fetchNui, isFiveM } from '@/core/nui';
import { PushLayer } from '../SettingsSubPage';

interface AppEntry { id: string; label: string }

const TONES = [
    'Default (Tri-tone)',
    'Apex',
    'Bamboo',
    'Chord',
    'Circles',
    'Cosmic',
    'Crystals',
    'Hillside',
    'Night Owl',
    'Opening',
    'Playtime',
    'Radar',
    'Reflection',
    'Ripple',
    'Sencha',
    'Silence',
];

export function AppNotificationsPage({
    app, onBack,
}: {
    app: AppEntry;
    onBack: () => void;
}) {
    const { goBack, pageStyle } = useIosPush(onBack);
    const [enabled,      setEnabled]      = useState(true);
    const [sounds,       setSounds]       = useState(true);
    const [tone,         setTone]         = useState('Default (Tri-tone)');
    const [showTonePicker, setShowTonePicker] = useState(false);

    useNuiQuery<{ enabled: boolean }>('sd-phone:settings:getNotifPref', {
        payload: { app: app.id },
        enabled: isFiveM,
        onData: d => setEnabled(d.enabled),
    });

    function changeEnabled(v: boolean) {
        setEnabled(v);
        if (isFiveM) void fetchNui('sd-phone:settings:setNotifPref', { app: app.id, on: v });
    }

    const subNode = showTonePicker ? (
        <TonePickerPage
            selected={tone}
            onSelect={t => { setTone(t); setShowTonePicker(false); }}
            onBack={() => setShowTonePicker(false)}
            appLabel={app.label}
        />
    ) : null;

    return (
        <PushLayer pageStyle={pageStyle} className="z-30" sub={subNode}>
            <div className="h-11 shrink-0" aria-hidden />

            <NavBar backLabel={t('settings.notifications', 'Notifications')} onBack={goBack} title={app.label} hairline />

            <div className="flex-1 overflow-y-auto no-scrollbar">
                <div className="mt-6 flex flex-col gap-6 px-4 pb-10">

                    <div className="flex flex-col items-center gap-3 py-2">
                        <AppTile iconId={app.id} />
                        <span className="text-[20px] font-semibold text-black dark:text-white">
                            {app.label}
                        </span>
                    </div>

                    <div className="overflow-hidden rounded-[10px] bg-[#e5e5e5] dark:bg-[#1C1C1E]">
                        <ToggleRow
                            label={t('settings.allowNotifications', 'Allow Notifications')}
                            on={enabled}
                            onChange={changeEnabled}
                        />
                    </div>

                    {enabled && (
                        <div className="overflow-hidden rounded-[10px] bg-[#e5e5e5] dark:bg-[#1C1C1E]">
                            <ToggleRow
                                label={t('settings.sounds', 'Sounds')}
                                on={sounds}
                                onChange={setSounds}
                                divider
                            />

                            <button
                                type="button"
                                onClick={() => setShowTonePicker(true)}
                                className="relative flex w-full items-center px-4 py-3 text-left active:bg-black/5 dark:active:bg-white/5"
                            >
                                <span className="flex-1 text-[17px] font-normal text-black dark:text-white">
                                    {t('settings.textTone', 'Text Tone')}
                                </span>
                                <span className="mr-1.5 text-[15px] text-ios-gray">
                                    {tone === 'Default (Tri-tone)' ? t('settings.default', 'Default') : tone}
                                </span>
                                <ChevronRight className="h-[17px] w-[17px] shrink-0 text-ios-gray3" strokeWidth={2.5} />
                            </button>
                        </div>
                    )}

                    {!enabled && (
                        <p className="px-1 text-[13px] text-ios-gray">
                            {t('settings.appNotifsOff', 'Notifications for {app} are turned off. Turn on Allow Notifications to receive alerts.', { app: app.label })}
                        </p>
                    )}
                </div>
            </div>
        </PushLayer>
    );
}


function TonePickerPage({
    selected, onSelect, onBack, appLabel,
}: {
    selected: string;
    onSelect: (t: string) => void;
    onBack: () => void;
    appLabel: string;
}) {
    const { goBack, pageStyle } = useIosPush(onBack);
    return (
        <div className="absolute inset-0 z-40 flex flex-col bg-[#d4d4d4] dark:bg-black" style={pageStyle}>
            <div className="h-11 shrink-0" aria-hidden />

            <NavBar backLabel={appLabel} onBack={goBack} title={t('settings.textTone', 'Text Tone')} hairline />

            <div className="flex-1 overflow-y-auto no-scrollbar">
                <div className="mt-6 px-4 pb-10">
                    <div className="overflow-hidden rounded-[10px] bg-[#e5e5e5] dark:bg-[#1C1C1E]">
                        {TONES.map((t, i) => (
                            <button
                                key={t}
                                type="button"
                                onClick={() => onSelect(t)}
                                className="relative flex w-full items-center px-4 py-3 text-left active:bg-black/5 dark:active:bg-white/5"
                            >
                                <span className="flex-1 text-[17px] font-normal text-black dark:text-white">
                                    {t}
                                </span>
                                {selected === t && (
                                    <Check className="h-[17px] w-[17px] shrink-0 text-ios-blue" strokeWidth={2.5} />
                                )}
                                {i < TONES.length - 1 && (
                                    <div
                                        className="pointer-events-none absolute bottom-0 right-0 bg-ios-gray4 dark:bg-[#38383A]"
                                        style={{ left: 0, height: '0.5px' }}
                                    />
                                )}
                            </button>
                        ))}
                    </div>
                </div>
            </div>
        </div>
    );
}


function AppTile({ iconId }: { iconId: string }) {
    const SIZE = 64, SVG_SIZE = 60, scale = SIZE / SVG_SIZE;
    return (
        <div style={{
            width: SIZE, height: SIZE,
            borderRadius: '27.6%',
            overflow: 'hidden',
            boxShadow: '0 2px 10px rgba(0,0,0,0.2)',
            position: 'relative',
        }}>
            <div style={{
                position: 'absolute', top: 0, left: 0,
                width: SVG_SIZE, height: SVG_SIZE,
                transform: `scale(${scale})`,
                transformOrigin: 'top left',
            }}>
                <AppIconSVG icon={iconId} />
            </div>
        </div>
    );
}

function ToggleRow({
    label, on, onChange, divider,
}: {
    label: string; on: boolean; onChange: (v: boolean) => void; divider?: boolean;
}) {
    return (
        <button
            type="button"
            onClick={() => onChange(!on)}
            className="relative flex w-full items-center px-4 py-3 text-left active:bg-black/5 dark:active:bg-white/5"
        >
            <span className="flex-1 text-[17px] font-normal text-black dark:text-white">{label}</span>
            <div className="pointer-events-none">
                <Toggle on={on} />
            </div>
            {divider && (
                <div
                    className="pointer-events-none absolute bottom-0 right-0 bg-ios-gray4 dark:bg-[#38383A]"
                    style={{ left: 0, height: '0.5px' }}
                />
            )}
        </button>
    );
}
