package com.itinerarios.e2e.support;

import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.openqa.selenium.OutputType;
import org.openqa.selenium.TakesScreenshot;
import org.openqa.selenium.WebDriver;
import org.openqa.selenium.support.ui.WebDriverWait;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.time.Duration;

public abstract class SeleniumTestBase {

    protected static final String BASE_URL = System.getProperty("e2e.baseUrl", "http://localhost:4200");
    /** Capturas de cada paso: evidencia visual del E2E para el reporte de entrega. */
    private static final Path SCREENSHOTS = Path.of(System.getProperty("e2e.screenshotsDir", "target/e2e-screenshots"));

    protected WebDriver driver;
    protected WebDriverWait wait;
    private int step;

    @BeforeEach
    void setUpDriver() {
        driver = WebDriverFactory.createChromeDriver();
        wait = new WebDriverWait(driver, Duration.ofSeconds(10));
    }

    @AfterEach
    void tearDownDriver() {
        if (driver != null) {
            driver.quit();
        }
    }

    /** Guarda "NN-nombre.png" con la pantalla actual. */
    protected void capture(String name) {
        try {
            Files.createDirectories(SCREENSHOTS);
            Path png = ((TakesScreenshot) driver).getScreenshotAs(OutputType.FILE).toPath();
            Files.copy(png, SCREENSHOTS.resolve(String.format("%02d-%s.png", ++step, name)), StandardCopyOption.REPLACE_EXISTING);
        } catch (IOException ex) {
            throw new UncheckedIOException("No se pudo guardar la captura " + name, ex);
        }
    }

    /** Pausa breve para que animaciones y graficos terminen de pintar antes de una captura. */
    protected void settle(long millis) {
        try {
            Thread.sleep(millis);
        } catch (InterruptedException ex) {
            Thread.currentThread().interrupt();
        }
    }
}
