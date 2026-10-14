using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace FlashSale.OrderService.Migrations
{
    /// <inheritdoc />
    public partial class AddCorrelationIdToOrders : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<string>(
                name: "CorrelationId",
                schema: "order_service",
                table: "orders",
                type: "text",
                nullable: false,
                defaultValue: "");

            migrationBuilder.CreateIndex(
                name: "IX_orders_CorrelationId",
                schema: "order_service",
                table: "orders",
                column: "CorrelationId");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropIndex(
                name: "IX_orders_CorrelationId",
                schema: "order_service",
                table: "orders");

            migrationBuilder.DropColumn(
                name: "CorrelationId",
                schema: "order_service",
                table: "orders");
        }
    }
}
