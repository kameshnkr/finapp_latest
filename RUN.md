//Run Commands

Dev Environment(./backend):
    Backend:
        $ nvm use v22.17.1
        $ npm run dev
    Frontend(./frontend_flutter): 
        $ flutter run --dart-define=API_BASE=http://localhost:3000


Live:
    Frontend(./frontend_flutter): 
        $ flutter build apk --release --dart-define=API_BASE=https://finapp-api-production.up.railway.app