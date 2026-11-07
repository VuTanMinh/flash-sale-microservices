# FlashSale Shop demo page

`index.html` is the demo storefront: a sliding hero, a flash-sale screen and a
technology logo strip. The flash-sale screen works in two modes:

- **Live API.** It sends `POST /api/orders` with an `Idempotency-Key` through
  Nginx, then polls `GET /api/orders/{id}` once a second until the order is
  Completed or Rejected. It handles 429, and 503 with `Retry-After`, by waiting
  and retrying with the same key. The order is kept in the browser, so after a
  reload it is read back from the database.
- **Simulation.** It runs in the browser with the project's numbers. This
  mode starts automatically when the API cannot be reached.

## Run it

1. Start the stack and the three services (`docs/setup-and-run.md`, steps 1–3).
2. Start the page server. It serves the page and forwards `/api/*` to the
   gateway, so the page and the API share one origin:

   ```powershell
   node demo-results/ui/serve.mjs                          # gateway at http://localhost:8080
   node demo-results/ui/serve.mjs --api http://<ec2-host>  # another gateway
   ```

3. Open http://localhost:5180. Add `?product=<id>` to order another seeded
   product (the default is `flash-product-1`).

Opening `index.html` directly as a file gives the simulation only.

`screenshots/` holds desktop, phone and dark-mode screenshots, taken on
7 November 2026. The live-mode shots (02, 08, 11) come from real orders on the
local stack: e51d5af9 on c0-demo-product went to Completed, then 589f8862 on
the same product and 963c7241 on flash-product-1 were Rejected, as both were
sold out in Redis. The others show the simulation and the static sections.

Logos are from Simple Icons 13.21.0 (CC0), inlined in the page. Fonts are
Lato, Assistant and Abel from Google Fonts, with system fonts as fallback.
