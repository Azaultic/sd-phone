import { useCallback, useState } from 'react';
import type { Dispatch, SetStateAction } from 'react';

const sessionStore = new Map<string, unknown>();

export function useSessionState<T>(key: string, initial: T | (() => T)): [T, Dispatch<SetStateAction<T>>] {
    const [value, setValue] = useState<T>(() => {
        if (sessionStore.has(key)) return sessionStore.get(key) as T;
        return typeof initial === 'function' ? (initial as () => T)() : initial;
    });

    const set = useCallback<Dispatch<SetStateAction<T>>>(action => {
        setValue(prev => {
            const next = typeof action === 'function' ? (action as (p: T) => T)(prev) : action;
            sessionStore.set(key, next);
            return next;
        });
    }, [key]);

    return [value, set];
}

export function seedSessionState<T>(key: string, value: T): void {
    sessionStore.set(key, value);
}

export function clearSessionState(prefix: string): void {
    for (const key of [...sessionStore.keys()]) {
        if (key.startsWith(prefix)) sessionStore.delete(key);
    }
}
