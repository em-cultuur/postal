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
      // Implement modal or redirect to details page
      console.log('View details for:', mxDomain);
    });
  });
});
