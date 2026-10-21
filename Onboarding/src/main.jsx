import { createRoot } from "react-dom/client";
import App from "./App.jsx";
import { I18nProvider } from "./i18n.jsx";
import "@fontsource/zcool-xiaowei/chinese-simplified-400.css";
import "misans/lib/Normal/MiSans-Regular.min.css";
import "misans/lib/Normal/MiSans-Medium.min.css";
import "./styles.css";

createRoot(document.getElementById("root")).render(
  <I18nProvider>
    <App />
  </I18nProvider>,
);
