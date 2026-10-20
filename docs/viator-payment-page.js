(function () {
  'use strict';

  var COUNTRY_CODES = (
    'AD AE AF AG AI AL AM AO AQ AR AS AT AU AW AX AZ BA BB BD BE BF BG BH BI BJ BL BM BN BO BQ BR BS BT BV BW BY BZ ' +
    'CA CC CD CF CG CH CI CK CL CM CN CO CR CU CV CW CX CY CZ DE DJ DK DM DO DZ EC EE EG EH ER ES ET FI FJ FK FM FO FR ' +
    'GA GB GD GE GF GG GH GI GL GM GN GP GQ GR GS GT GU GW GY HK HM HN HR HT HU ID IE IL IM IN IO IQ IR IS IT JE JM JO JP ' +
    'KE KG KH KI KM KN KP KR KW KY KZ LA LB LC LI LK LR LS LT LU LV LY MA MC MD ME MF MG MH MK ML MM MN MO MP MQ MR MS MT ' +
    'MU MV MW MX MY MZ NA NC NE NF NG NI NL NO NP NR NU NZ OM PA PE PF PG PH PK PL PM PN PR PS PT PW PY QA RE RO RS RU RW ' +
    'SA SB SC SD SE SG SH SI SJ SK SL SM SN SO SR SS ST SV SX SY SZ TC TD TF TG TH TJ TK TL TM TN TO TR TT TV TW TZ UA UG ' +
    'UM US UY UZ VA VC VE VG VI VN VU WF WS YE YT ZA ZM ZW'
  ).split(' ');

  var FATAL_CODES = ['INVALID_PAYMENT_SESSION_TOKEN', 'PAYMENT_SESSION_EXPIRED', 'INVALID_CONFIGURATION'];

  var RETRY_MESSAGES = {
    MISSING_DATA: 'Please check the billing country and postal code.',
    CARD_DETAILS_INVALID: 'The card was declined or its details are invalid. Please check them or use another card.',
    THREEDS_CANCELLED: 'Card verification was cancelled. Please try again.',
    THREEDS_FAILED: 'Card verification failed. Please try again or use another card.',
    SERVICE_UNAVAILABLE: 'The payment service is not responding. Please try again.'
  };
  var GENERIC_RETRY_MESSAGE = 'The payment could not be completed. Please try again.';
  var POSTAL_CODE_PATTERN = /^[A-Za-z0-9][A-Za-z0-9 -]*$/;

  var LIBRARY_WAIT_MS = 10000;
  var LIBRARY_POLL_MS = 50;

  var payButton = null;
  var cancelButton = null;
  var countrySelect = null;
  var postalCodeInput = null;
  var errorLabel = null;

  var payment = null;
  var formValid = false;
  var submitting = false;
  var readyPosted = false;
  var finished = false;

  /** Sends one contract message to the native host, iOS first and Android otherwise. */
  function post(message) {
    var handlers = window.webkit && window.webkit.messageHandlers;
    if (handlers && handlers.viatorPayment) {
      handlers.viatorPayment.postMessage(message);
    } else if (window.AndroidViator) {
      if (message.event === 'success') window.AndroidViator.onPaymentSuccess(message.paymentToken);
      else if (message.event === 'error') window.AndroidViator.onPaymentError(message.message || '');
      else if (message.event === 'cancel') window.AndroidViator.onPaymentCancel();
    }
  }

  /** Tears the form down and posts the final message; anything after the first final message is dropped. */
  function finish(message) {
    if (finished) return;
    finished = true;
    destructPayment();
    updatePayButton();
    post(message);
  }

  /** Posts `error`, carrying the PaymentError code when there is one. */
  function fail(error, fallbackCode) {
    var message = { event: 'error', message: (error && error.message) || String(error) };
    var code = (error && error.errorCode) || fallbackCode;
    if (code) message.code = code;
    finish(message);
  }

  function destructPayment() {
    if (!payment) return;
    try { payment.destruct(); } catch (ignored) {}
    payment = null;
  }

  function billingAddress() {
    return { country: countrySelect.value, postalCode: postalCodeInput.value.trim() };
  }

  function updatePayButton() {
    if (!payButton) return;
    var address = billingAddress();
    payButton.disabled = finished || submitting || !payment || !formValid ||
      !address.country || !POSTAL_CODE_PATTERN.test(address.postalCode);
  }

  /** Handles the card iframe's FormEvent; the live library also emits FORM_OVERDUE and FORM_ERROR. */
  function onFormUpdate(event) {
    if (finished || !event) return;
    switch (event.eventType) {
      case 'FORM_LOADED':
        formValid = !!event.formValid;
        if (!readyPosted) {
          readyPosted = true;
          post({ event: 'ready' });
        }
        break;
      case 'FORM_CHANGED':
        formValid = !!event.formValid;
        break;
      case 'FORM_OVERDUE':
        if (!readyPosted) fail({ message: 'The card form did not load in time.' }, 'SERVICE_UNAVAILABLE');
        return;
      case 'FORM_ERROR':
        fail({ message: 'The card form could not be loaded.' }, 'SERVICE_UNAVAILABLE');
        return;
    }
    updatePayButton();
  }

  function submit() {
    if (payButton.disabled) return;
    submitting = true;
    errorLabel.textContent = '';
    updatePayButton();
    payment.submitForm({ address: billingAddress() }).then(function (response) {
      if (response && response.paymentToken) {
        finish({ event: 'success', paymentToken: response.paymentToken });
      } else {
        submitting = false;
        errorLabel.textContent = GENERIC_RETRY_MESSAGE;
        updatePayButton();
      }
    }, function (error) {
      submitting = false;
      var code = error && error.errorCode;
      if (FATAL_CODES.indexOf(code) !== -1) {
        fail(error);
        return;
      }
      errorLabel.textContent = RETRY_MESSAGES[code] || GENERIC_RETRY_MESSAGE;
      updatePayButton();
    });
  }

  function cancel() {
    finish({ event: 'cancel' });
  }

  /** Fills the country list with localized names, preselecting the region of the device locale. */
  function populateCountries(language) {
    var names = null;
    try { names = new Intl.DisplayNames([language, 'en'], { type: 'region' }); } catch (ignored) {}
    var countries = COUNTRY_CODES.map(function (code) {
      return { code: code, name: (names && names.of(code)) || code };
    }).sort(function (a, b) { return a.name.localeCompare(b.name, language); });

    var placeholder = document.createElement('option');
    placeholder.value = '';
    placeholder.textContent = 'Select';
    countrySelect.replaceChildren(placeholder);
    countries.forEach(function (country) {
      var option = document.createElement('option');
      option.value = country.code;
      option.textContent = country.name;
      countrySelect.appendChild(option);
    });

    var region = deviceRegion();
    if (region && COUNTRY_CODES.indexOf(region) !== -1) countrySelect.value = region;
  }

  function deviceRegion() {
    var locale = navigator.language || '';
    try {
      var region = new Intl.Locale(locale).maximize().region;
      if (region) return region.toUpperCase();
    } catch (ignored) {}
    var parts = locale.split(/[-_]/);
    return parts.length > 1 && /^[A-Za-z]{2}$/.test(parts[parts.length - 1]) ? parts[parts.length - 1].toUpperCase() : null;
  }

  /** Looks the form elements up once the document is parsed and wires their events. */
  function bindElements() {
    if (payButton) return;
    payButton = document.getElementById('pay');
    cancelButton = document.getElementById('cancel');
    countrySelect = document.getElementById('country');
    postalCodeInput = document.getElementById('postal-code');
    errorLabel = document.getElementById('error');
    payButton.addEventListener('click', submit);
    cancelButton.addEventListener('click', cancel);
    countrySelect.addEventListener('change', updatePayButton);
    postalCodeInput.addEventListener('input', updatePayButton);
  }

  function whenDocumentReady(callback) {
    if (document.readyState !== 'loading') callback();
    else document.addEventListener('DOMContentLoaded', callback, { once: true });
  }

  /** Calls back with true once Viator's module has defined window.Payment, or false after LIBRARY_WAIT_MS. */
  function whenLibraryReady(callback) {
    var deadline = Date.now() + LIBRARY_WAIT_MS;
    (function check() {
      if (window.Payment && typeof window.Payment.init === 'function') callback(true);
      else if (Date.now() >= deadline) callback(false);
      else setTimeout(check, LIBRARY_POLL_MS);
    })();
  }

  /**
   * Entry point the native host calls once the page has loaded. It can be called before the document is parsed or
   * before Viator's module has run; the form starts as soon as both are in place.
   * @param {{sessionToken: string, language?: string}} options paymentSessionToken from the booking hold and a base language code.
   */
  function start(options) {
    whenDocumentReady(function () {
      bindElements();
      whenLibraryReady(function (loaded) { begin(options, loaded); });
    });
  }

  function begin(options, libraryLoaded) {
    var sessionToken = options && options.sessionToken;
    var language = (options && options.language) || 'en';
    document.documentElement.lang = language;
    populateCountries(language);

    if (!sessionToken) {
      fail({ message: 'No payment session token was provided.' }, 'INVALID_PAYMENT_SESSION_TOKEN');
      return;
    }
    if (!libraryLoaded) {
      fail({ message: 'The payment library could not be loaded.' }, 'SERVICE_UNAVAILABLE');
      return;
    }

    destructPayment();
    finished = false;
    readyPosted = false;
    formValid = false;
    submitting = false;
    errorLabel.textContent = '';
    try {
      payment = window.Payment.init(sessionToken);
      payment.renderCard({
        cardElementContainer: '#card-form',
        onFormUpdate: onFormUpdate,
        styling: { colorTheme: 'LIGHT', variables: { colorBackground: '#FFFFFF', colorPrimaryText: '#111111' } }
      });
    } catch (error) {
      fail(error, 'SERVICE_UNAVAILABLE');
      return;
    }
    updatePayButton();
  }

  window.trpViatorPayment = { start: start, cancel: cancel };
})();
