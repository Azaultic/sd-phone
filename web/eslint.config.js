import tseslint from 'typescript-eslint';
import reactHooks from 'eslint-plugin-react-hooks';

export default tseslint.config(
    { ignores: ['build/**', 'node_modules/**', 'src/render/three/**', '*.config.js', '*.config.cjs', '*.config.ts'] },
    ...tseslint.configs.recommended,
    {
        files: ['src/**/*.{ts,tsx}'],
        plugins: { 'react-hooks': reactHooks },
        rules: {
            // Only the two classic hooks rules: the v6 compiler-era additions
            // (react-hooks/refs, set-state-in-render, …) reject the deliberate
            // latest-ref pattern used across useNuiEvent/useAsyncData/SlideOver.
            'react-hooks/rules-of-hooks': 'error',
            'react-hooks/exhaustive-deps': 'warn',
            // tsc (noUnusedLocals) already errors on unused vars; the eslint
            // duplicate would double-report with different escape hatches.
            '@typescript-eslint/no-unused-vars': 'off',
            // Both used deliberately at NUI/vendor boundaries.
            '@typescript-eslint/no-explicit-any': 'off',
            '@typescript-eslint/no-non-null-assertion': 'off',
            // Codebase relies on {} spreads over payload unions.
            '@typescript-eslint/no-empty-object-type': 'off',
        },
    },
);
