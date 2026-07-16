import { digits } from './format';

export function formatPhone(value: string): string {
    const d = digits(value);
    if (d.length === 10) return `(${d.slice(0, 3)}) ${d.slice(3, 6)}-${d.slice(6)}`;
    return value;
}

export function formatPhonePartial(value: string): string {
    const d = digits(value);
    if (d.length === 0) return '';
    if (d.length <= 3) return d;
    if (d.length <= 6) return `(${d.slice(0, 3)}) ${d.slice(3)}`;
    const tail = d.length > 10 ? ` ${d.slice(10)}` : '';
    return `(${d.slice(0, 3)}) ${d.slice(3, 6)}-${d.slice(6, 10)}${tail}`;
}
