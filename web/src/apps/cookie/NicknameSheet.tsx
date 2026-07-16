import { useRef, useState } from 'react';

import { t } from '@/i18n';
import { Sheet } from '@/ui/Sheet';

export function NicknameSheet({ initial, onClose, onSave }: {
    initial: string;
    onClose: () => void;
    onSave:  (name: string) => void;
}) {
    const [name, setName] = useState(initial);
    const pendingSave = useRef(false);

    function handleClose() {
        if (pendingSave.current) { onSave(name.trim()); return; }
        onClose();
    }

    return (
        <Sheet onClose={handleClose} fit="content" durationMs={240} grabber={false} className="bg-[#f3ece1] text-[#5B3A1A]">
            {({ close }) => {
                function save() { pendingSave.current = true; close(); }
                return (
                    <>
                        <div className="flex justify-center pb-1 pt-3">
                            <div className="h-[5px] w-9 rounded-full bg-[#9C6B33]/30" />
                        </div>
                        <div className="flex items-center justify-between px-5 pb-3 pt-1">
                            <button type="button" onClick={close} className="text-[17px] text-[#C77D2E] active:opacity-60">{t('cookie.cancel', 'Cancel')}</button>
                            <span className="text-[17px] font-semibold">{t('cookie.leaderboardName', 'Leaderboard Name')}</span>
                            <button type="button" onClick={save} className="text-[17px] font-semibold text-[#C77D2E] active:opacity-60">{t('cookie.save', 'Save')}</button>
                        </div>
                        <div className="px-4 pt-1">
                            <p className="mb-2 px-1 text-[12px] uppercase tracking-widest text-[#9C6B33]/70">{t('cookie.shownOnLeaderboard', 'Shown on the leaderboard')}</p>
                            <div className="overflow-hidden rounded-[10px] bg-white">
                                <input
                                    value={name}
                                    onChange={e => setName(e.target.value)}
                                    onKeyDown={e => { if (e.key === 'Enter') save(); }}
                                    placeholder={t('cookie.characterNamePlaceholder', 'Your character name')}
                                    maxLength={20}
                                    className="w-full bg-transparent px-4 py-3 text-[17px] text-[#5B3A1A] placeholder-[#9C6B33]/45 outline-none"
                                />
                            </div>
                            <p className="mt-2 px-1 text-[13px] text-[#9C6B33]/70">{t('cookie.aliasHint', 'Pick a custom alias, or clear it to use your character name.')}</p>
                        </div>
                    </>
                );
            }}
        </Sheet>
    );
}
