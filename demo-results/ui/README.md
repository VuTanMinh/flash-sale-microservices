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

1. Start the local stack, load the stock and start the three services, each in
   its own window, from the repository root:

   ```powershell
   docker compose -f infra/docker-compose.yml up -d
   powershell -ExecutionPolicy Bypass -File .\scripts\warm-up.ps1 -Force
   dotnet run --project src\FlashSale.OrderService
   dotnet run --project src\FlashSale.InventoryService
   dotnet run --project src\FlashSale.ProcessWorker
   ```

   The warm-up must print `Warm-up complete and confirmed.` Run it again before
   a new demo: a sold-out product rejects every order.
2. Start the page server. It serves the page and forwards `/api/*` to the
   gateway, so the page and the API share one origin:

   ```powershell
   node demo-results/ui/serve.mjs                          # gateway at http://localhost:8080
   node demo-results/ui/serve.mjs --api http://<ec2-host>  # another gateway
   ```

3. Open http://localhost:5180. Add `?product=<id>` to order another seeded
   product (the default is `flash-product-1`).

Opening `index.html` directly as a file gives the simulation only.

## Styling and what needs internet

The page is styled with Bootstrap 5.3.3: navbar, cards, grid rows, buttons,
order-state badges (one colour per state), alerts for 429, 503 and errors, and
tables for the order's state history and IDs. The shop's own colours and fonts
are applied on top through Bootstrap's CSS variables, and Bootstrap's dark mode
follows the page's theme switch.

Everything the page needs to start is vendored in `vendor/`, each with its
MIT `LICENSE`, so it runs without internet:
- `bootstrap-5.3.3/bootstrap.min.css`. The page uses no Bootstrap JavaScript.
- `react-18.3.1/react.production.min.js` and `react-dom.production.min.js`
  (React 18.3.1).
- `babel-standalone-7.23.5/babel.min.js`.

Only the Lato, Assistant and Abel fonts come from Google Fonts. Without
internet the page falls back to system fonts.

`screenshots/` holds desktop, phone and dark-mode screenshots, all taken on
19 November 2026 with the Bootstrap styling.
- 01, 04, 05, 06, 07 and 10 show the simulation and the static sections.
- The live-mode shots (02, 08 and 11) come from real orders on the local stack:
  - 63a546b7 on c0-demo-product went to Completed. A second POST with the same
    Idempotency-Key returned 200 and the same order.
  - fe654b6d on the same product was Rejected, as its one unit was gone.
  - 8662a96d on flash-product-1 (phone) went to Completed.

Logos are from Simple Icons 13.21.0 (CC0), inlined in the page. Fonts are
Lato, Assistant and Abel from Google Fonts, with system fonts as fallback.
