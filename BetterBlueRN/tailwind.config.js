/** @type {import('tailwindcss').Config} */
module.exports = {
  content: ['./app/**/*.{tsx,ts}', './src/**/*.{tsx,ts}'],
  darkMode: 'class',
  theme: {
    extend: {
      colors: {
        primary: '#2563eb',
        'bg-dark': '#0f172a',
        'surface-dark': '#1e293b',
        accent: '#3b82f6',
        danger: '#ef4444',
        success: '#22c55e',
        warning: '#f97316',
      },
    },
  },
  plugins: [],
};
