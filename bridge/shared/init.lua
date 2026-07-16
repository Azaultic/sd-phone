-- Loaded for side effects: framework detection runs once (and hard-errors with install guidance
-- when no supported framework is started, aborting the resource on purpose).
require 'bridge.shared.framework'
-- Loaded for side effects: the locale boot thread loads locales/<config.Locale>.json.
require 'bridge.shared.locale'
