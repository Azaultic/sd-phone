import type { InputHTMLAttributes, ReactNode } from 'react';

import { t } from '@/i18n';

export function SheetHeader({ title, onCancel, right }: {
    title:    string;
    onCancel: () => void;
    right:    ReactNode;
}) {
    return (
        <div className="flex items-center justify-between px-5 pb-3 pt-1">
            <button type="button" onClick={onCancel} className="text-[17px] text-ios-blue active:opacity-60">{t('darkchat.cancel', 'Cancel')}</button>
            <span className="text-[17px] font-semibold">{title}</span>
            {right}
        </div>
    );
}

export function SheetAction({ label, onClick, disabled = false }: {
    label:     string;
    onClick:   () => void;
    disabled?: boolean;
}) {
    return (
        <button type="button" onClick={onClick} disabled={disabled} className="text-[17px] font-semibold text-ios-blue disabled:opacity-35 active:opacity-60">{label}</button>
    );
}

export function SheetField({ label, hint, error, inputClassName, ...input }: {
    label:           string;
    hint?:           string;
    error?:          string;
    inputClassName?: string;
} & InputHTMLAttributes<HTMLInputElement>) {
    return (
        <div className="px-4 pt-1">
            <p className="mb-2 px-1 text-[12px] uppercase tracking-widest text-white/40">{label}</p>
            <div className="overflow-hidden rounded-[10px] bg-[#2c2c2e]">
                <input
                    {...input}
                    className={inputClassName ?? 'w-full bg-transparent px-4 py-3 text-[17px] text-white placeholder-white/30 outline-none'}
                />
            </div>
            {error
                ? <p className="mt-2 px-1 text-[13px] text-[#ff453a]">{error}</p>
                : hint && <p className="mt-2 px-1 text-[13px] text-white/40">{hint}</p>}
        </div>
    );
}
