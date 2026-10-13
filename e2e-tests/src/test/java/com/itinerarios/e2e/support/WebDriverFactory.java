package com.itinerarios.e2e.support;

import org.openqa.selenium.WebDriver;
import org.openqa.selenium.chrome.ChromeDriver;
import org.openqa.selenium.chrome.ChromeOptions;

/**
 * Selenium 4.6+ incluye Selenium Manager: resuelve automáticamente el
 * binario de ChromeDriver compatible con el Chrome instalado, sin
 * necesidad de WebDriverManager como dependencia adicional.
 */
public final class WebDriverFactory {

    private WebDriverFactory() {
    }

    public static WebDriver createChromeDriver() {
        ChromeOptions options = new ChromeOptions();
        boolean headless = !"false".equalsIgnoreCase(System.getProperty("e2e.headless", "true"));
        if (headless) {
            options.addArguments("--headless=new");
        }
        options.addArguments("--window-size=1366,900");
        options.addArguments("--no-sandbox");
        options.addArguments("--disable-dev-shm-usage");
        return new ChromeDriver(options);
    }
}
