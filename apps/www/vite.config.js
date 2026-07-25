import { defineConfig } from "vite";
import { resolve } from "node:path";
import preact from "@preact/preset-vite";

export default defineConfig({
  plugins: [preact()],
  build: {
    rollupOptions: {
      input: {
        main: resolve(import.meta.dirname, "index.html"),
        yukariRubi: resolve(import.meta.dirname, "yukari-rubi/index.html"),
        yukariRubiPrivacy: resolve(import.meta.dirname, "yukari-rubi/privacy/index.html"),
      },
    },
  },
});
