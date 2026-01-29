document.addEventListener('turbolinks:load', function() {
  var chartContainer = document.getElementById('mxRateLimitingChart');
  
  if (chartContainer && window.Chartist) {
    var chartData = JSON.parse(chartContainer.dataset.chartData || '{}');
    
    if (chartData.labels && chartData.labels.length > 0) {
      new Chartist.Line('#mxRateLimitingChart', {
        labels: chartData.labels,
        series: [
          chartData.errors || [],
          chartData.successes || []
        ]
      }, {
        lineSmooth: Chartist.Interpolation.simple({
          divisor: 2
        }),
        fullWidth: true,
        chartPadding: {
          top: 15,
          right: 10,
          bottom: 5,
          left: 60
        },
        height: '300px'
      });
      
      // Add legend
      var legend = document.querySelector('.mxRateLimitingDashboard__chartLegend');
      if (legend) {
        legend.style.display = 'flex';
      }
    }
  }

  // View MX details modal
  document.querySelectorAll('.js-view-details').forEach(function(link) {
    link.addEventListener('click', function(e) {
      e.preventDefault();
      var mxDomain = this.dataset.mxDomain;
      openMXDetailsModal(mxDomain);
    });
  });

  // Close modal handlers
  document.querySelectorAll('.js-close-modal').forEach(function(el) {
    el.addEventListener('click', function() {
      closeMXDetailsModal();
    });
  });

  // Delete rate limit handlers
  document.querySelectorAll('.js-delete-rate-limit').forEach(function(link) {
    link.addEventListener('click', function(e) {
      e.preventDefault();
      var mxDomain = this.dataset.mxDomain;
      deleteMXRateLimit(mxDomain, this);
    });
  });

  function openMXDetailsModal(mxDomain) {
    var modal = document.getElementById('mxDetailsModal');
    var loadingEl = modal.querySelector('.mxDetailsModal__loading');
    var errorEl = modal.querySelector('.mxDetailsModal__error');
    var contentEl = modal.querySelector('.mxDetailsModal__content');

    // Show modal and loading state
    modal.style.display = 'block';
    loadingEl.style.display = 'block';
    errorEl.style.display = 'none';
    contentEl.style.display = 'none';

    // Build URL - get current path and construct stats URL
    var pathParts = window.location.pathname.split('/');
    var orgIndex = pathParts.indexOf('org');
    var serverIndex = pathParts.indexOf('servers');
    
    if (orgIndex === -1 || serverIndex === -1) {
      showModalError();
      return;
    }

    var orgId = pathParts[orgIndex + 1];
    var serverId = pathParts[serverIndex + 1];
    var statsUrl = '/org/' + orgId + '/servers/' + serverId + '/mx_rate_limits/' + encodeURIComponent(mxDomain) + '/stats';

    // Fetch data
    fetch(statsUrl, {
      headers: {
        'Accept': 'application/json',
        'X-Requested-With': 'XMLHttpRequest'
      }
    })
    .then(function(response) {
      if (!response.ok) {
        throw new Error('Network response was not ok');
      }
      return response.json();
    })
    .then(function(data) {
      populateModalContent(data);
      loadingEl.style.display = 'none';
      contentEl.style.display = 'block';
    })
    .catch(function(error) {
      console.error('Error fetching MX details:', error);
      showModalError();
    });
  }

  function populateModalContent(data) {
    var modal = document.getElementById('mxDetailsModal');
    var rateLimit = data.rate_limit;
    var events = data.events_last_24h || [];

    // Populate summary fields
    modal.querySelector('.js-mx-domain').textContent = rateLimit.mx_domain;
    modal.querySelector('.js-current-delay').textContent = formatDelayHuman(rateLimit.current_delay_seconds);
    modal.querySelector('.js-error-count').textContent = rateLimit.error_count;
    modal.querySelector('.js-success-count').textContent = rateLimit.success_count;
    modal.querySelector('.js-last-error').textContent = formatTimestamp(rateLimit.last_error_at);
    modal.querySelector('.js-last-success').textContent = formatTimestamp(rateLimit.last_success_at);
    modal.querySelector('.js-last-error-message').textContent = rateLimit.last_error_message || '--';

    // Populate events table
    var eventsContainer = modal.querySelector('.js-events-container');
    if (events.length === 0) {
      eventsContainer.innerHTML = '<p class="noData__text">No events in the last 24 hours</p>';
    } else {
      var tableHtml = '<table class="dataTable"><thead><tr>' +
        '<th>Time</th><th>Event Type</th><th>SMTP Response</th>' +
        '</tr></thead><tbody>';
      
      events.forEach(function(event) {
        var eventTime = new Date(event.created_at);
        var timeStr = eventTime.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' });
        var eventTypeClass = 'mxRateLimitingDashboard__eventBadge event-' + event.event_type;
        
        tableHtml += '<tr>' +
          '<td>' + timeStr + '</td>' +
          '<td><span class="' + eventTypeClass + '">' + formatEventType(event.event_type) + '</span></td>' +
          '<td>' + (event.smtp_response ? '<code>' + event.smtp_response + '</code>' : '--') + '</td>' +
          '</tr>';
      });
      
      tableHtml += '</tbody></table>';
      eventsContainer.innerHTML = tableHtml;
    }
  }

  function showModalError() {
    var modal = document.getElementById('mxDetailsModal');
    modal.querySelector('.mxDetailsModal__loading').style.display = 'none';
    modal.querySelector('.mxDetailsModal__error').style.display = 'block';
    modal.querySelector('.mxDetailsModal__content').style.display = 'none';
  }

  function closeMXDetailsModal() {
    var modal = document.getElementById('mxDetailsModal');
    modal.style.display = 'none';
  }

  function formatDelayHuman(seconds) {
    if (seconds === 0) return 'No delay';
    if (seconds < 60) return seconds + 's';
    if (seconds < 3600) {
      var minutes = Math.round(seconds / 60 * 10) / 10;
      return (minutes % 1 === 0 ? Math.floor(minutes) : minutes) + 'm';
    }
    var hours = Math.round(seconds / 3600 * 10) / 10;
    return (hours % 1 === 0 ? Math.floor(hours) : hours) + 'h';
  }

  function formatTimestamp(timestamp) {
    if (!timestamp) return '--';
    var date = new Date(timestamp);
    var now = new Date();
    var diffMs = now - date;
    var diffSecs = Math.floor(diffMs / 1000);
    var diffMins = Math.floor(diffSecs / 60);
    var diffHours = Math.floor(diffMins / 60);
    var diffDays = Math.floor(diffHours / 24);

    if (diffDays > 0) return diffDays + ' day' + (diffDays > 1 ? 's' : '') + ' ago';
    if (diffHours > 0) return diffHours + ' hour' + (diffHours > 1 ? 's' : '') + ' ago';
    if (diffMins > 0) return diffMins + ' minute' + (diffMins > 1 ? 's' : '') + ' ago';
    return 'just now';
  }

  function formatEventType(eventType) {
    return eventType.replace(/_/g, ' ').replace(/\b\w/g, function(l) { return l.toUpperCase(); });
  }

  function deleteMXRateLimit(mxDomain, linkElement) {
    if (!confirm('Are you sure you want to delete the rate limit for "' + mxDomain + '"?\n\nThis will remove all rate limiting rules and event history for this MX domain.')) {
      return;
    }

    // Build URL
    var pathParts = window.location.pathname.split('/');
    var orgIndex = pathParts.indexOf('org');
    var serverIndex = pathParts.indexOf('servers');
    
    if (orgIndex === -1 || serverIndex === -1) {
      alert('Error: Unable to construct deletion URL');
      return;
    }

    var orgId = pathParts[orgIndex + 1];
    var serverId = pathParts[serverIndex + 1];
    var deleteUrl = '/org/' + orgId + '/servers/' + serverId + '/mx_rate_limits/' + encodeURIComponent(mxDomain);

    // Get CSRF token
    var csrfToken = document.querySelector('meta[name="csrf-token"]');
    if (!csrfToken) {
      alert('Error: CSRF token not found');
      return;
    }

    // Disable the link during deletion
    linkElement.style.pointerEvents = 'none';
    linkElement.style.opacity = '0.5';
    var originalText = linkElement.textContent;
    linkElement.textContent = 'Deleting...';

    // Send DELETE request
    fetch(deleteUrl, {
      method: 'DELETE',
      headers: {
        'Accept': 'application/json',
        'X-Requested-With': 'XMLHttpRequest',
        'X-CSRF-Token': csrfToken.content
      }
    })
    .then(function(response) {
      if (!response.ok) {
        throw new Error('Network response was not ok');
      }
      return response.json();
    })
    .then(function(data) {
      // Remove the table row
      var row = linkElement.closest('tr');
      if (row) {
        row.style.transition = 'opacity 0.3s ease';
        row.style.opacity = '0';
        setTimeout(function() {
          row.remove();
          
          // Check if table is now empty
          var tbody = document.querySelector('.mxRateLimitingDashboard__section tbody');
          if (tbody && tbody.querySelectorAll('tr').length === 0) {
            // Reload page to show "no data" message
            window.location.reload();
          }
        }, 300);
      }
    })
    .catch(function(error) {
      console.error('Error deleting MX rate limit:', error);
      alert('Error deleting rate limit. Please try again.');
      
      // Re-enable the link
      linkElement.style.pointerEvents = '';
      linkElement.style.opacity = '';
      linkElement.textContent = originalText;
    });
  }
});
