/** @type {import('tailwindcss').Config} */
module.exports = {
  content: ["./index.html", "./src/**/*.{ts,tsx}"],
  theme: {
    extend: {
      fontFamily: {
        sans: ["Inter", "ui-sans-serif", "system-ui", "sans-serif"],
      },
      colors: {
        ink: "#20251f",
        muted: "#858b82",
        leaf: "#47765a",
        paper: "#f7f8f5",
      },
      boxShadow: {
        card: "0 24px 70px -38px rgba(34, 48, 37, 0.3)",
      },
    },
  },
  plugins: [],
};
