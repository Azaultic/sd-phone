export function readJson<T>(key: string, validate?: (v: unknown) => boolean): T | null {
    try {
        const raw = localStorage.getItem(key);
        if (raw === null) return null;
        const parsed = JSON.parse(raw) as unknown;
        if (validate && !validate(parsed)) return null;
        return parsed as T;
    } catch {
        return null;
    }
}

export function writeJson(key: string, value: unknown): boolean {
    try {
        localStorage.setItem(key, JSON.stringify(value));
        return true;
    } catch {
        return false;
    }
}
