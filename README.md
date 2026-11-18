# IRPC_BARCODE_FE_WebBoardman

## Run locally

1. Install the Node.js version supported by the Angular 21 toolchain.
2. Install dependencies:

   ```sh
   npm install
   ```

3. Start the frontend:

   ```sh
   npm start
   ```

4. Open [http://localhost:4200](http://localhost:4200).

## API and sign-in

- The development frontend uses `http://localhost:5100` as its API base URL. Start the matching backend locally, or change `baseAPIURL` in `src/environments/environment.development.ts` to the API server you are authorized to use.
- The default/production environment points to the Q Track service configured in `src/environments/environment.ts`.
- Demo login, mock permissions, and demo Special List records are disabled. Sign in with a valid account from the configured backend. Without a reachable API, sign-in and data loading will not work.

## Build

```sh
npm run build
```